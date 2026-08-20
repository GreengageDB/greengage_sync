/*-------------------------------------------------------------------------
 *
 * nodeSplitUpdate.c
 *	  Implementation of nodeSplitUpdate.
 *
 * Portions Copyright (c) 2012, EMC Corp.
 * Portions Copyright (c) 2012-Present VMware, Inc. or its affiliates.
 *
 *
 * IDENTIFICATION
 *	    src/backend/executor/nodeSplitUpdate.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "miscadmin.h"

#include "cdb/cdbhash.h"
#include "cdb/cdbutil.h"
#include "commands/tablecmds.h"
#include "executor/instrument.h"
#include "executor/nodeSplitUpdate.h"

#include "utils/memutils.h"

/* Splits an update tuple into a DELETE/INSERT tuples. */
static void SplitTupleTableSlot(TupleTableSlot *slot,
								List *targetList, SplitUpdate *plannode, SplitUpdateState *node,
								Datum *values, bool *nulls);

/* Memory used by node */
#define SPLITUPDATE_MEM 1


/*
 * Evaluate the hash keys, and compute the target segment ID for the new row.
 */
static uint32
evalHashKey(SplitUpdateState *node, CdbHash *h, int numHashAttrs,
			AttrNumber *hashAttnos, Datum *values, bool *isnulls)
{
	ExprContext *econtext = node->ps.ps_ExprContext;
	MemoryContext oldContext;
	unsigned int target_seg;

	ResetExprContext(econtext);

	oldContext = MemoryContextSwitchTo(econtext->ecxt_per_tuple_memory);

	cdbhashinit(h);

	for (int i = 0; i < numHashAttrs; i++)
	{
		AttrNumber	keyattno = hashAttnos[i];

		/*
		 * Compute the hash function
		 */
		cdbhash(h, i + 1, values[keyattno - 1], isnulls[keyattno - 1]);
	}
	target_seg = cdbhashreduce(h);

	MemoryContextSwitchTo(oldContext);

	return target_seg;
}

/* Split TupleTableSlot into a DELETE and INSERT TupleTableSlot */
static void
SplitTupleTableSlot(TupleTableSlot *slot,
					List *targetList, SplitUpdate *plannode, SplitUpdateState *node,
					Datum *values, bool *nulls)
{
	ListCell *element;
	ListCell *deleteAtt = list_head(plannode->deleteColIdx);
	ListCell *insertAtt = list_head(plannode->insertColIdx);

	slot_getallattrs(slot);
	Datum	   *delete_values = node->deleteTuple->tts_values;
	bool	   *delete_nulls = node->deleteTuple->tts_isnull;
	Datum	   *insert_values = node->insertTuple->tts_values;
	bool	   *insert_nulls = node->insertTuple->tts_isnull;

	/* Iterate through new TargetList and match old and new values. The action is also added in this containsTuple. */
	foreach (element, targetList)
	{
		TargetEntry *tle = lfirst(element);
		AttrNumber attno = tle->resno;

		if (IsA(tle->expr, DMLActionExpr))
		{
			/* Set the corresponding action to the new tuples. */
			delete_values[attno - 1] = Int32GetDatum((int)DML_DELETE);
			delete_nulls[attno - 1] = false;

			insert_values[attno - 1] = Int32GetDatum((int)DML_INSERT);
			insert_nulls[attno -1 ] = false;
		}
		else if (attno <= list_length(plannode->insertColIdx))
		{
			/* Old and new values */
			int			deleteAttNo = lfirst_int(deleteAtt);
			int			insertAttNo = lfirst_int(insertAtt);

			if (deleteAttNo == -1)
			{
				delete_values[attno - 1] = (Datum) 0;
				delete_nulls[attno - 1] = true;
			}
			else
			{
				delete_values[attno - 1] = values[deleteAttNo - 1];
				delete_nulls[attno - 1] = nulls[deleteAttNo - 1];
			}

			insert_values[attno - 1] = values[insertAttNo - 1];
			insert_nulls[attno - 1] = nulls[insertAttNo - 1];

			deleteAtt = lnext(plannode->deleteColIdx, deleteAtt);
			insertAtt = lnext(plannode->insertColIdx, insertAtt);
		}
		else if (attno == node->output_segid_attno)
		{
			Assert(!nulls[node->input_segid_attno - 1]);

			delete_values[attno - 1] = values[node->input_segid_attno - 1];
			delete_nulls[attno - 1] = false;

			/* compute the new value later, after we have processed all the other columns */
		}
		else
		{
			if (IsA(tle->expr, Var))
			{
				Var		   *var = (Var *) tle->expr;

				Assert(var->varno == OUTER_VAR);

				delete_values[attno - 1] = values[var->varattno - 1];
				delete_nulls[attno - 1] = nulls[var->varattno - 1];

				insert_values[attno - 1] = values[var->varattno - 1];
				insert_nulls[attno - 1] = nulls[var->varattno - 1];

				Assert(var->vartype == TupleDescAttr(slot->tts_tupleDescriptor, var->varattno - 1)->atttypid);
			}
			/* `Resjunk' values */
		}
	}

	/* Compute segment ID for the new row */
	if (node->output_segid_attno > 0)
	{
		int32		target_seg;
		CdbHash	   *h = node->cdbhash;
		int			numHashAttrs = plannode->numHashAttrs;
		AttrNumber *hashAttnos = plannode->hashAttnos;

		/*
		 * GPDB: for an old-style inheritance target, the members' policies
		 * can differ; select the source relation's own policy by the
		 * "tableoid" junk column.  A NULL hash object means the relation's
		 * placement cannot change (randomly distributed, or its key does not
		 * exist in the nominal layout): keep the row on its old segment.
		 */
		if (node->numPolicies > 0 && node->input_tableoid_attno > 0 &&
			!nulls[node->input_tableoid_attno - 1])
		{
			Oid			relid = DatumGetObjectId(values[node->input_tableoid_attno - 1]);
			int			idx = node->lastPolicyIdx;

			if (idx < 0 || node->policyRelids[idx] != relid)
			{
				idx = -1;
				for (int i = 0; i < node->numPolicies; i++)
				{
					if (node->policyRelids[i] == relid)
					{
						idx = i;
						break;
					}
				}
				node->lastPolicyIdx = idx;
			}

			if (idx >= 0)
			{
				h = node->policyCdbHash[idx];
				numHashAttrs = node->policyNattrs[idx];
				hashAttnos = node->policyAttnos[idx];
			}
		}

		if (h != NULL && numHashAttrs > 0)
			target_seg = evalHashKey(node, h, numHashAttrs, hashAttnos,
									 insert_values, insert_nulls);
		else
		{
			/* keep the row on its old segment */
			Assert(!nulls[node->input_segid_attno - 1]);
			target_seg = DatumGetInt32(values[node->input_segid_attno - 1]);
		}

		insert_values[node->output_segid_attno - 1] = Int32GetDatum(target_seg);
		insert_nulls[node->output_segid_attno - 1] = false;
	}
}

/**
 * Splits every TupleTableSlot into two TupleTableSlots: DELETE and INSERT.
 */
static TupleTableSlot *
ExecSplitUpdate(PlanState *pstate)
{
	SplitUpdateState *node = castNode(SplitUpdateState, pstate);
	PlanState *outerNode = outerPlanState(node);
	SplitUpdate *plannode = (SplitUpdate *) node->ps.plan;

	TupleTableSlot *slot = NULL;
	TupleTableSlot *result = NULL;

	Assert(outerNode != NULL);

	/* Returns INSERT TupleTableSlot. */
	if (!node->processInsert)
	{
		result = node->insertTuple;

		node->processInsert = true;
	}
	else
	{
		/* Creates both TupleTableSlots. Returns DELETE TupleTableSlots.*/
		slot = ExecProcNode(outerNode);

		if (TupIsNull(slot))
		{
			return NULL;
		}

		/* `Split' update into delete and insert */
		slot_getallattrs(slot);
		Datum	   *values = slot->tts_values;
		bool	   *nulls = slot->tts_isnull;

		ExecStoreAllNullTuple(node->deleteTuple);
		ExecStoreAllNullTuple(node->insertTuple);

		SplitTupleTableSlot(slot, plannode->plan.targetlist, plannode, node, values, nulls);

		result = node->deleteTuple;
		node->processInsert = false;

	}

	return result;
}

/*
 * Init SplitUpdate Node. A memory context is created to hold Split Tuples.
 * */
SplitUpdateState*
ExecInitSplitUpdate(SplitUpdate *node, EState *estate, int eflags)
{
	SplitUpdateState *splitupdatestate;

	/* Check for unsupported flags */
	Assert(!(eflags & (EXEC_FLAG_BACKWARD | EXEC_FLAG_MARK | EXEC_FLAG_REWIND)));

	splitupdatestate = makeNode(SplitUpdateState);
	splitupdatestate->ps.plan = (Plan *)node;
	splitupdatestate->ps.state = estate;
	splitupdatestate->ps.ExecProcNode = ExecSplitUpdate;
	splitupdatestate->processInsert = true;

	/*
	 * then initialize outer plan
	 */
	Plan *outerPlan = outerPlan(node);
	outerPlanState(splitupdatestate) = ExecInitNode(outerPlan, estate, eflags);

	ExecAssignExprContext(estate, &splitupdatestate->ps);

	/*
	 * New TupleDescriptor for output TupleTableSlots (old_values + new_values, ctid,
	 * gp_segment, action).
	 */
	TupleDesc tupDesc = ExecTypeFromTL(node->plan.targetlist);
	splitupdatestate->insertTuple = ExecInitExtraTupleSlot(estate, tupDesc, &TTSOpsVirtual);
	splitupdatestate->deleteTuple = ExecInitExtraTupleSlot(estate, tupDesc, &TTSOpsVirtual);

	/*
	 * Look up the positions of the gp_segment_id in the subplan's target
	 * list, and in the result.
	 */
	splitupdatestate->input_segid_attno =
		ExecFindJunkAttributeInTlist(outerPlan->targetlist, "gp_segment_id");
	splitupdatestate->output_segid_attno =
		ExecFindJunkAttributeInTlist(node->plan.targetlist, "gp_segment_id");

	/*
	 * GPDB: set up the per-result-relation placement policies of an
	 * old-style inheritance target (see SplitUpdate in plannodes.h).  The
	 * row's source relation is identified by the "tableoid" junk column.
	 */
	splitupdatestate->input_tableoid_attno =
		ExecFindJunkAttributeInTlist(outerPlan->targetlist, "tableoid");
	splitupdatestate->numPolicies = list_length(node->policyRelids);
	splitupdatestate->lastPolicyIdx = -1;
	if (splitupdatestate->numPolicies > 0)
	{
		int			npol = splitupdatestate->numPolicies;
		int			i;
		ListCell   *lcrelid;
		ListCell   *lcattnos;
		ListCell   *lcfuncs;
		ListCell   *lcnumsegs;

		Assert(list_length(node->policyAttnos) == npol);
		Assert(list_length(node->policyFuncs) == npol);
		Assert(list_length(node->policyNumSegments) == npol);

		splitupdatestate->policyRelids = (Oid *) palloc(npol * sizeof(Oid));
		splitupdatestate->policyCdbHash = (CdbHash **) palloc0(npol * sizeof(CdbHash *));
		splitupdatestate->policyAttnos = (AttrNumber **) palloc0(npol * sizeof(AttrNumber *));
		splitupdatestate->policyNattrs = (int *) palloc0(npol * sizeof(int));

		i = 0;
		forfour(lcrelid, node->policyRelids,
				lcattnos, node->policyAttnos,
				lcfuncs, node->policyFuncs,
				lcnumsegs, node->policyNumSegments)
		{
			List	   *attnos = (List *) lfirst(lcattnos);
			List	   *funcs = (List *) lfirst(lcfuncs);
			int			nattrs = list_length(attnos);

			splitupdatestate->policyRelids[i] = lfirst_oid(lcrelid);
			if (nattrs > 0)
			{
				AttrNumber *attnoarr = (AttrNumber *) palloc(nattrs * sizeof(AttrNumber));
				Oid		   *funcarr = (Oid *) palloc(nattrs * sizeof(Oid));
				ListCell   *lc2;
				int			j;

				Assert(list_length(funcs) == nattrs);
				j = 0;
				foreach(lc2, attnos)
					attnoarr[j++] = (AttrNumber) lfirst_int(lc2);
				j = 0;
				foreach(lc2, funcs)
					funcarr[j++] = lfirst_oid(lc2);

				splitupdatestate->policyAttnos[i] = attnoarr;
				splitupdatestate->policyNattrs[i] = nattrs;
				splitupdatestate->policyCdbHash[i] =
					makeCdbHash(lfirst_int(lcnumsegs), nattrs, funcarr);
			}
			i++;
		}
	}

	/*
	 * DML nodes do not project.
	 */
	ExecInitResultTupleSlotTL(&splitupdatestate->ps, &TTSOpsVirtual);
	splitupdatestate->ps.ps_ProjInfo = NULL;

	/*
	 * Initialize for computing hash key
	 */
	if (node->numHashAttrs > 0)
	{
		splitupdatestate->cdbhash = makeCdbHash(node->numHashSegments,
												node->numHashAttrs,
												node->hashFuncs);
	}

	if (estate->es_instrument && (estate->es_instrument & INSTRUMENT_CDB))
	{
		splitupdatestate->ps.cdbexplainbuf = makeStringInfo();
	}

	return splitupdatestate;
}

/* Release Resources Requested by SplitUpdate node. */
void
ExecEndSplitUpdate(SplitUpdateState *node)
{
	ExecFreeExprContext(&node->ps);
	ExecClearTuple(node->ps.ps_ResultTupleSlot);
	ExecClearTuple(node->insertTuple);
	ExecClearTuple(node->deleteTuple);
	ExecEndNode(outerPlanState(node));
}


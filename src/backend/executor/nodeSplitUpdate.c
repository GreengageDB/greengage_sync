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
evalHashKey(SplitUpdateState *node, CdbHash *h,
			int numHashAttrs, AttrNumber *hashAttnos,
			Datum *values, bool *isnulls)
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

/*
 * Find the per-relation placement policy for a row, by the OID in its
 * "tableoid" junk column.  Returns -1 if the plan carries no per-relation
 * policies, or if the row's relation has none of its own.
 *
 * Rows arrive grouped by relation in practice (the subplan is an Append over
 * the members), so remembering the previous answer avoids the search almost
 * always.
 */
static int
lookupPolicyIdx(SplitUpdateState *node, Datum *values, bool *isnulls)
{
	Oid			relid;
	int			idx;

	if (node->numPolicies == 0 || node->input_tableoid_attno <= 0)
		return -1;

	if (isnulls[node->input_tableoid_attno - 1])
		elog(ERROR, "tableoid is NULL");
	relid = DatumGetObjectId(values[node->input_tableoid_attno - 1]);

	idx = node->lastPolicyIdx;
	if (idx >= 0 && node->policyRelids[idx] == relid)
		return idx;

	for (idx = 0; idx < node->numPolicies; idx++)
	{
		if (node->policyRelids[idx] == relid)
		{
			node->lastPolicyIdx = idx;
			return idx;
		}
	}

	elog(ERROR, "no split-update placement policy for relation %u", relid);
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
		int			numHashAttrs = plannode->numHashAttrs;
		AttrNumber *hashAttnos = plannode->hashAttnos;
		CdbHash    *h = node->cdbhash;
		int			idx;

		/*
		 * If the target is an inheritance tree whose members are distributed
		 * differently, place the row according to its own relation's policy
		 * rather than the nominal relation's.
		 */
		idx = lookupPolicyIdx(node, values, nulls);
		if (idx >= 0)
		{
			numHashAttrs = node->policyNumHashAttrs[idx];
			hashAttnos = node->policyAttnos[idx];

			if (node->policyHashes[idx] == NULL && numHashAttrs > 0)
				node->policyHashes[idx] = makeCdbHash(node->policyNumSegments[idx],
													  numHashAttrs,
													  node->policyFuncs[idx]);
			h = node->policyHashes[idx];
		}

		if (numHashAttrs > 0)
		{
			int32		target_seg;

			Assert(h != NULL);
			target_seg = evalHashKey(node, h, numHashAttrs, hashAttnos,
									 insert_values, insert_nulls);

			insert_values[node->output_segid_attno - 1] = Int32GetDatum(target_seg);
		}
		else
		{
			/*
			 * Nothing to hash on: the row cannot have moved, so re-insert it
			 * on the segment it came from.
			 */
			Assert(!nulls[node->input_segid_attno - 1]);
			insert_values[node->output_segid_attno - 1] =
				values[node->input_segid_attno - 1];
		}
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
	 * For an inheritance tree, each row says which relation it came from, so
	 * that we can place it by that relation's own distribution policy.
	 */
	splitupdatestate->input_tableoid_attno =
		ExecFindJunkAttributeInTlist(outerPlan->targetlist, "tableoid");
	splitupdatestate->lastPolicyIdx = -1;
	splitupdatestate->numPolicies = list_length(node->policyRelids);
	if (splitupdatestate->numPolicies > 0)
	{
		int			npol = splitupdatestate->numPolicies;
		ListCell   *lcrelid;
		ListCell   *lcattnos;
		ListCell   *lcfuncs;
		ListCell   *lcnsegs;
		int			i = 0;

		Assert(list_length(node->policyAttnos) == npol);
		Assert(list_length(node->policyFuncs) == npol);
		Assert(list_length(node->policyNumSegments) == npol);

		splitupdatestate->policyRelids = (Oid *) palloc(npol * sizeof(Oid));
		splitupdatestate->policyNumHashAttrs = (int *) palloc(npol * sizeof(int));
		splitupdatestate->policyAttnos = (AttrNumber **) palloc(npol * sizeof(AttrNumber *));
		splitupdatestate->policyFuncs = (Oid **) palloc(npol * sizeof(Oid *));
		splitupdatestate->policyNumSegments = (int *) palloc(npol * sizeof(int));
		splitupdatestate->policyHashes = (CdbHash **) palloc0(npol * sizeof(CdbHash *));

		forfour(lcrelid, node->policyRelids,
				lcattnos, node->policyAttnos,
				lcfuncs, node->policyFuncs,
				lcnsegs, node->policyNumSegments)
		{
			List	   *attnos = (List *) lfirst(lcattnos);
			List	   *funcs = (List *) lfirst(lcfuncs);
			int			nattrs = list_length(attnos);
			ListCell   *lc;
			int			k;

			Assert(list_length(funcs) == nattrs);

			splitupdatestate->policyRelids[i] = lfirst_oid(lcrelid);
			splitupdatestate->policyNumHashAttrs[i] = nattrs;
			splitupdatestate->policyNumSegments[i] = lfirst_int(lcnsegs);

			if (nattrs > 0)
			{
				splitupdatestate->policyAttnos[i] =
					(AttrNumber *) palloc(nattrs * sizeof(AttrNumber));
				splitupdatestate->policyFuncs[i] =
					(Oid *) palloc(nattrs * sizeof(Oid));

				k = 0;
				foreach(lc, attnos)
					splitupdatestate->policyAttnos[i][k++] = (AttrNumber) lfirst_int(lc);
				k = 0;
				foreach(lc, funcs)
					splitupdatestate->policyFuncs[i][k++] = lfirst_oid(lc);
			}
			else
			{
				splitupdatestate->policyAttnos[i] = NULL;
				splitupdatestate->policyFuncs[i] = NULL;
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


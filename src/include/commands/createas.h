/*-------------------------------------------------------------------------
 *
 * createas.h
 *	  prototypes for createas.c.
 *
 *
 * Portions Copyright (c) 1996-2021, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/commands/createas.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef CREATEAS_H
#define CREATEAS_H

#include "catalog/objectaddress.h"
#include "nodes/params.h"
#include "parser/parse_node.h"
#include "tcop/dest.h"
#include "utils/queryenvironment.h"


extern ObjectAddress ExecCreateTableAs(ParseState *pstate, CreateTableAsStmt *stmt,
									   ParamListInfo params, QueryEnvironment *queryEnv,
									   QueryCompletion *qc);

extern int	GetIntoRelEFlags(IntoClause *intoClause);

extern DestReceiver *CreateIntoRelDestReceiver(IntoClause *intoClause);

<<<<<<< HEAD
struct QueryDesc;
extern void intorel_initplan(struct QueryDesc *queryDesc, int eflags);
=======
extern bool CreateTableAsRelExists(CreateTableAsStmt *ctas);
>>>>>>> f315205f3fafd6f6c7c479f480289fcf45700310

#endif							/* CREATEAS_H */

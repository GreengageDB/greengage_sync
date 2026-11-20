/*
 * This is a mock version of src/backend/access/transam/rmgr.c. The real
 * rmgr.c contains a table of the WAL redo/desc functions for all the WAL
 * record types. Leave out the table, so that we can leave out the AM
 * object files, which helps to cut down the size of the test programs.
 *
 * The table is left empty, so RmgrIdExists() reports every resource manager
 * as unregistered and the startup/cleanup loops below do nothing.
 */
#include "postgres.h"

#include "access/rmgr.h"
#include "access/xlog_internal.h"

RmgrData	RmgrTable[RM_MAX_ID + 1];

void
RmgrStartup(void)
{
	for (int rmid = 0; rmid <= RM_MAX_ID; rmid++)
	{
		if (!RmgrIdExists(rmid))
			continue;

		if (RmgrTable[rmid].rm_startup != NULL)
			RmgrTable[rmid].rm_startup();
	}
}

void
RmgrCleanup(void)
{
	for (int rmid = 0; rmid <= RM_MAX_ID; rmid++)
	{
		if (!RmgrIdExists(rmid))
			continue;

		if (RmgrTable[rmid].rm_cleanup != NULL)
			RmgrTable[rmid].rm_cleanup();
	}
}

void
RmgrNotFound(RmgrId rmid)
{
	ereport(ERROR, (errmsg("resource manager with ID %d not registered", rmid),
					errhint("Include the extension module that implements this resource manager in shared_preload_libraries.")));
}

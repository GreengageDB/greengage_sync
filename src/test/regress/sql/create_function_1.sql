--
-- CREATE_FUNCTION_1
--

-- directory path and dlsuffix are passed to us in environment variables
\getenv libdir PG_LIBDIR
\getenv dlsuffix PG_DLSUFFIX

\set regresslib :libdir '/regress' :dlsuffix

-- Create C functions needed by create_type.sql

CREATE FUNCTION widget_in(cstring)
   RETURNS widget
<<<<<<< HEAD:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C IMMUTABLE STRICT NO SQL;
||||||| 3b231596ccf:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C STRICT IMMUTABLE;
=======
   AS :'regresslib'
   LANGUAGE C STRICT IMMUTABLE;
>>>>>>> c4cc2850f4d:src/test/regress/sql/create_function_1.sql

CREATE FUNCTION widget_out(widget)
   RETURNS cstring
<<<<<<< HEAD:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C IMMUTABLE STRICT NO SQL;
||||||| 3b231596ccf:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C STRICT IMMUTABLE;
=======
   AS :'regresslib'
   LANGUAGE C STRICT IMMUTABLE;
>>>>>>> c4cc2850f4d:src/test/regress/sql/create_function_1.sql

CREATE FUNCTION int44in(cstring)
   RETURNS city_budget
<<<<<<< HEAD:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C IMMUTABLE STRICT NO SQL;
||||||| 3b231596ccf:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C STRICT IMMUTABLE;
=======
   AS :'regresslib'
   LANGUAGE C STRICT IMMUTABLE;
>>>>>>> c4cc2850f4d:src/test/regress/sql/create_function_1.sql

CREATE FUNCTION int44out(city_budget)
   RETURNS cstring
<<<<<<< HEAD:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C IMMUTABLE STRICT NO SQL;
||||||| 3b231596ccf:src/test/regress/input/create_function_1.source
   AS '@libdir@/regress@DLSUFFIX@'
   LANGUAGE C STRICT IMMUTABLE;
=======
   AS :'regresslib'
   LANGUAGE C STRICT IMMUTABLE;
>>>>>>> c4cc2850f4d:src/test/regress/sql/create_function_1.sql

-- Run manually in the Supabase SQL Editor for the PIAAR Work project.
-- One SELECT; metadata only. No schema changes, user rows, or friendship actions.
-- Return the contract JSON so the app can match the actual server schema.
WITH target_tables AS (
    SELECT c.oid, n.nspname AS schema_name, c.relname AS table_name,
           c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS force_rls
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('profiles', 'friend_requests', 'friendships')
      AND c.relkind IN ('r', 'p')
), relevant_functions AS (
    SELECT p.*, n.nspname AS schema_name
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg_toast%'
      AND p.prokind = 'f'
      AND (p.proname ILIKE '%friend%' OR p.proname ILIKE '%profile%')
)
SELECT jsonb_pretty(jsonb_build_object(
    'tables', COALESCE((
        SELECT jsonb_agg(to_jsonb(t) - 'oid' ORDER BY table_name)
        FROM target_tables t
    ), '[]'::jsonb),
    'columns', COALESCE((
        SELECT jsonb_agg(to_jsonb(a) ORDER BY table_name, ordinal_position)
        FROM (
            SELECT table_schema, table_name, ordinal_position, column_name,
                   data_type, udt_schema, udt_name, is_nullable, column_default,
                   is_identity, is_generated
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name IN ('profiles', 'friend_requests', 'friendships')
        ) a
    ), '[]'::jsonb),
    'constraints', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'table', t.table_name, 'name', con.conname, 'type', con.contype,
            'validated', con.convalidated, 'deferrable', con.condeferrable,
            'definition', pg_get_constraintdef(con.oid, true)
        ) ORDER BY t.table_name, con.conname)
        FROM pg_constraint con JOIN target_tables t ON con.conrelid = t.oid
    ), '[]'::jsonb),
    'indexes', COALESCE((
        SELECT jsonb_agg(to_jsonb(i) ORDER BY tablename, indexname)
        FROM pg_indexes i
        WHERE schemaname = 'public'
          AND tablename IN ('profiles', 'friend_requests', 'friendships')
    ), '[]'::jsonb),
    'policies', COALESCE((
        SELECT jsonb_agg(to_jsonb(p) ORDER BY tablename, policyname)
        FROM pg_policies p
        WHERE schemaname = 'public'
          AND tablename IN ('profiles', 'friend_requests', 'friendships')
    ), '[]'::jsonb),
    'table_grants', COALESCE((
        SELECT jsonb_agg(to_jsonb(g) ORDER BY table_name, grantee, privilege_type)
        FROM information_schema.role_table_grants g
        WHERE table_schema = 'public'
          AND table_name IN ('profiles', 'friend_requests', 'friendships')
          AND grantee IN ('PUBLIC', 'anon', 'authenticated')
    ), '[]'::jsonb),
    'column_grants', COALESCE((
        SELECT jsonb_agg(to_jsonb(g) ORDER BY table_name, column_name, grantee, privilege_type)
        FROM information_schema.role_column_grants g
        WHERE table_schema = 'public'
          AND table_name IN ('profiles', 'friend_requests', 'friendships')
          AND grantee IN ('PUBLIC', 'anon', 'authenticated')
    ), '[]'::jsonb),
    'functions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'schema', p.schema_name, 'name', p.proname,
            'identity_arguments', pg_get_function_identity_arguments(p.oid),
            'arguments', pg_get_function_arguments(p.oid),
            'result', pg_get_function_result(p.oid),
            'security_definer', p.prosecdef,
            'owner', pg_get_userbyid(p.proowner),
            'settings', p.proconfig, 'acl', p.proacl,
            'authenticated_execute', has_function_privilege('authenticated', p.oid, 'EXECUTE'),
            'anon_execute', has_function_privilege('anon', p.oid, 'EXECUTE'),
            'definition', pg_get_functiondef(p.oid)
        ) ORDER BY p.schema_name, p.proname, pg_get_function_identity_arguments(p.oid))
        FROM relevant_functions p
    ), '[]'::jsonb),
    'triggers', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'table', t.table_name, 'name', tr.tgname, 'enabled', tr.tgenabled,
            'definition', pg_get_triggerdef(tr.oid, true)
        ) ORDER BY t.table_name, tr.tgname)
        FROM pg_trigger tr JOIN target_tables t ON tr.tgrelid = t.oid
        WHERE NOT tr.tgisinternal
    ), '[]'::jsonb)
)) AS friend_contract;

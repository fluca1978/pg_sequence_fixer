-- complain if script is sourced in psql, rather than via CREATE EXTENSION
--\echo Use "CREATE EXTENSION pg_sequence_fixer" to load this file. \quit

CREATE OR REPLACE FUNCTION pg_sequence_fixer(IN v_margin int, IN v_lock_mode boolean DEFAULT false)
RETURNS void AS
$$
	DECLARE
		v_rec		RECORD;	
		v_sql		text;
	  v_max		int8;
    v_can   bool;
	BEGIN
		IF	v_margin IS NULL
		THEN 
			RAISE NOTICE 'the safety margin will be set to 1';
			v_margin := 1;
		END IF;

		IF 	v_margin < 1
		THEN
			RAISE WARNING 'a negative safety margin is used';
		END IF;
		
		FOR v_rec IN 
			SELECT  d.objid::regclass,
				d.refobjid::regclass,
				a.attname
			FROM 	pg_depend AS d
				JOIN pg_class AS t
					ON d.objid = t.oid
				JOIN pg_attribute AS a
					ON d.refobjid = a.attrelid 
						AND d.refobjsubid = a.attnum
			WHERE 	d.classid = 'pg_class'::regclass
				AND d.refclassid = 'pg_class'::regclass
				AND t.oid >= 16384
				AND t.relkind = 'S'
				AND d.deptype IN ('a', 'i')
		LOOP

      v_sql := 'SELECT has_sequence_privilege( ' || quote_literal(v_rec.objid::regclass) || ', ' || quote_literal( 'UPDATE' ) || ' )';
      EXECUTE v_sql INTO v_can;

      RAISE DEBUG 'Query [%] -> %', v_sql, v_can;

      IF NOT v_can THEN
        RAISE NOTICE 'You do not have rights on sequence % owned by %, skipping',
        quote_literal(v_rec.objid::regclass),
        v_rec.refobjid::text;

        CONTINUE;
      END IF;


			IF	v_lock_mode = true
			THEN
				v_sql := 'LOCK TABLE ' || v_rec.refobjid::regclass || ' IN EXCLUSIVE MODE';
				RAISE NOTICE 'locking: %', v_rec.refobjid::regclass;
				EXECUTE v_sql;
			END IF;

      -- compute the current max value in the table column
      v_sql := 'SELECT max( ' || quote_ident(v_rec.attname::text) || ' ) FROM ' || v_rec.refobjid::regclass;
      EXECUTE v_sql INTO v_max;

      RAISE DEBUG 'Current max value on %.% is %',
        v_rec.refobjid::regclass,
        quote_ident(v_rec.attname::text),
        v_max;

      IF v_max IS NOT NULL THEN
        
        -- check if the sequence does allow for the minimum value
        v_sql := 'SELECT EXISTS ( '
          || 'SELECT seqmin, seqmax FROM pg_sequence WHERE '
          || ' seqrelid = ' || quote_literal(v_rec.objid::regclass) || '::regclass '
          || ' AND seqmin <= ' || ( v_max + v_margin )
          || ' AND seqmax >= ' || ( v_max + v_margin )
          || ' )';
        EXECUTE v_sql INTO v_can;

        IF NOT v_can THEN

          RAISE NOTICE 'Sequence %, owned by %, does not accept value % + % = %',
          quote_literal(v_rec.objid::regclass),
          v_rec.refobjid::text,
          v_max,
          v_margin,
          ( v_max + v_margin );
          CONTINUE;
        END IF;


        -- if here, it does make sense to set the sequence value
        v_sql := 'SELECT setval(' || quote_literal(v_rec.objid::regclass) || '::text, '
          || ( v_max + v_margin )
				  || ')';

			  EXECUTE v_sql INTO v_max;
			  RAISE NOTICE 'set sequence owned by % to %', v_rec.refobjid::text, v_max;
      ELSE
        -- check if the user can issue an ALTER SEQUENCE
        v_sql := 'SELECT EXISTS( SELECT relowner, relname FROM pg_class c '
          || 'JOIN pg_roles r ON r.oid = c.relowner WHERE c.oid = ' || quote_literal(v_rec.objid::regclass) || '::regclass'
          || ' AND c.relkind = '|| quote_literal( 'S' ) || ' AND r.rolname = CURRENT_ROLE )';
        EXECUTE v_sql INTO v_can;

        IF NOT v_can THEN
          RAISE NOTICE 'Cannot reset sequence %, you must be the owner', quote_literal(v_rec.objid::regclass);
          CONTINUE;
        END IF;

        v_sql := 'ALTER SEQUENCE ' || v_rec.objid::regclass || ' RESTART ';
        EXECUTE v_sql;
        RAISE NOTICE 'reset sequence owned by %', v_rec.refobjid::text;
      END IF;


		END LOOP;

		RETURN;
	END;
$$ LANGUAGE 'plpgsql';


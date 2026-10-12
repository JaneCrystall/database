-- Synthetic-only behavior contract. All rows and Auth identities roll back.
BEGIN;
-- Test-only membership for SET ROLE, rolled back with all synthetic fixtures.
GRANT journals_reader, out_user TO postgres WITH SET TRUE;
DO $contract$
DECLARE
  actor uuid := gen_random_uuid();
  other_actor uuid := gen_random_uuid();
  edu_id uuid := gen_random_uuid();
  esg_id uuid := gen_random_uuid();
  standard_id uuid := gen_random_uuid();
  journal_id uuid := gen_random_uuid();
  green_id uuid := gen_random_uuid();
  own_role uuid := gen_random_uuid();
  other_role uuid := gen_random_uuid();
  marker text := 'synthetic' || replace(gen_random_uuid()::text,'-','');
  n integer;
  denied boolean;
BEGIN
  INSERT INTO auth.users(id,email) VALUES(actor,actor::text||'@example.invalid'),(other_actor,other_actor::text||'@example.invalid');
  INSERT INTO public.user_roles(id,user_id,role) VALUES(own_role,actor,'service_role'),(other_role,other_actor,'synthetic_reader');
  INSERT INTO public.edu_meta(id,name,language) VALUES(edu_id,marker,'eng');
  INSERT INTO public.esg_meta(id,report_title,company_name,language) VALUES(esg_id,marker,marker,'eng');
  INSERT INTO public.standards(id,title,standard_number) VALUES(standard_id,marker,marker);
  INSERT INTO public.journals(id,doi,title,authors) VALUES(journal_id,'10.99999/'||marker,marker,'["Synthetic Author"]'::jsonb);
  INSERT INTO public.green_deal_meta(id,title) VALUES(green_id,marker);

  IF NOT EXISTS(SELECT FROM public.esg_meta WHERE id=esg_id AND created_by=current_user AND created_time IS NOT NULL) THEN
    RAISE EXCEPTION 'Synthetic ESG insert trigger did not set session identity/time';
  END IF;
  UPDATE public.esg_meta SET report_title=marker||' updated' WHERE id=esg_id;
  IF NOT EXISTS(SELECT FROM public.esg_meta WHERE id=esg_id AND last_updated_by=current_user AND last_updated_time IS NOT NULL) THEN
    RAISE EXCEPTION 'Synthetic ESG update trigger did not set session identity/time';
  END IF;
  UPDATE public.green_deal_meta SET title=marker||' updated' WHERE id=green_id;
  IF NOT EXISTS(SELECT FROM public.green_deal_meta WHERE id=green_id AND last_updated_time IS NOT NULL) THEN
    RAISE EXCEPTION 'Synthetic green-deal update trigger did not set time';
  END IF;
  IF NOT public.has_service_role(actor) OR public.has_service_role(other_actor) THEN
    RAISE EXCEPTION 'Role lookup helper does not match synthetic role rows';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
  PERFORM set_config('request.jwt.claims',json_build_object('sub',actor,'role','authenticated')::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM public.edu_meta WHERE id=edu_id;
  IF n<>1 THEN RAISE EXCEPTION 'Authenticated education read failed'; END IF;
  SELECT count(*) INTO n FROM public.user_roles WHERE id IN(own_role,other_role);
  IF n<>1 THEN RAISE EXCEPTION 'User-role own-row policy failed'; END IF;
  SELECT count(*) INTO n FROM public.green_deal_meta WHERE id=green_id;
  IF n<>0 THEN RAISE EXCEPTION 'Policyless green-deal row became readable'; END IF;
  SELECT count(*) INTO n FROM public.esg_full_text(marker) WHERE id=esg_id;
  IF n<>1 THEN RAISE EXCEPTION 'Authenticated ESG full-text lookup failed'; END IF;
  SELECT count(*) INTO n FROM public.standards_full_text(marker) WHERE id=standard_id;
  IF n<>1 THEN RAISE EXCEPTION 'Authenticated standards full-text lookup failed'; END IF;
  denied:=false;
  BEGIN
    INSERT INTO public.edu_meta(name) VALUES(marker||' forbidden');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Authenticated insert unexpectedly permitted'; END IF;
  EXECUTE 'RESET ROLE';

  EXECUTE 'SET LOCAL ROLE anon';
  SELECT count(*) INTO n FROM public.edu_meta WHERE id=edu_id;
  IF n<>0 THEN RAISE EXCEPTION 'Anonymous education read unexpectedly permitted'; END IF;
  SELECT count(*) INTO n FROM public.esg_full_text(marker) WHERE id=esg_id;
  IF n<>0 THEN RAISE EXCEPTION 'Anonymous metadata RPC bypassed table RLS'; END IF;
  EXECUTE 'RESET ROLE';

  EXECUTE 'SET LOCAL ROLE journals_reader';
  SELECT count(*) INTO n FROM public.journals WHERE id=journal_id;
  IF n<>1 THEN RAISE EXCEPTION 'Journal reader SELECT privilege/policy failed'; END IF;
  denied:=false;
  BEGIN
    INSERT INTO public.journals(doi) VALUES('10.99999/'||marker||'-forbidden');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Journal reader insert unexpectedly permitted'; END IF;
  EXECUTE 'RESET ROLE';

  EXECUTE 'SET LOCAL ROLE out_user';
  SELECT count(*) INTO n FROM public.esg_meta WHERE id=esg_id;
  IF n<>0 THEN RAISE EXCEPTION 'out_user bypassed ESG RLS'; END IF;
  EXECUTE 'RESET ROLE';
END
$contract$;
ROLLBACK;

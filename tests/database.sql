\set ON_ERROR_STOP on
BEGIN;
-- Rolled back at the end. Prevent pre-existing jobs from entering the test claim.
UPDATE api.conversations SET status='paused' WHERE status IN ('queued','running');
DO $$
DECLARE sid uuid; cid uuid; j jsonb; old_token uuid; ok boolean; n integer; v text;
BEGIN
 sid:=api.save_scenario(jsonb_build_object('title','Integration test','topic','Test topic','rounds',1,'participants',
 jsonb_build_array(
 jsonb_build_object('name','A','personality','analyst','model_profile_id','10000000-0000-0000-0000-000000000001'),
 jsonb_build_object('name','B','personality','skeptic','model_profile_id','10000000-0000-0000-0000-000000000001'))));
 cid:=api.create_conversation(sid);
 PERFORM api.control_conversation(cid,'start');
 PERFORM api.control_conversation(cid,'start');
 SELECT count(*) INTO n FROM api.jobs WHERE conversation_id=cid;
 IF n<>1 THEN RAISE EXCEPTION 'Duplicate job'; END IF;
 j:=api.claim_turn();
 IF j->>'id'<>cid::text THEN RAISE EXCEPTION 'Wrong claim'; END IF;
 old_token:=(j->>'token')::uuid;
 IF api.claim_turn() IS NOT NULL THEN RAISE EXCEPTION 'Active lease claimed twice'; END IF;
 PERFORM api.control_conversation(cid,'pause');
 ok:=api.finish_turn(cid,old_token,'Stale response',12);
 IF ok THEN RAISE EXCEPTION 'Paused turn was committed'; END IF;
 PERFORM api.control_conversation(cid,'start');
 j:=api.claim_turn();
 PERFORM api.post_message(cid,'A human contribution');
 ok:=api.finish_turn(cid,(j->>'token')::uuid,'First response',12);
 IF NOT ok THEN RAISE EXCEPTION 'Valid turn rejected'; END IF;
 ok:=api.finish_turn(cid,(j->>'token')::uuid,'Duplicate response',12);
 IF ok THEN RAISE EXCEPTION 'Duplicate response committed'; END IF;
 j:=api.claim_turn();
 -- Expired lease recovery and old-token rejection.
 old_token:=(j->>'token')::uuid;
 UPDATE api.jobs SET leased_until=now()-interval '1 second' WHERE conversation_id=cid;
 j:=api.claim_turn();
 IF (j->>'token')::uuid=old_token THEN RAISE EXCEPTION 'Lease was not renewed'; END IF;
 IF api.finish_turn(cid,old_token,'Expired response',1) THEN RAISE EXCEPTION 'Expired token committed'; END IF;
 -- Error can be retried without advancing the turn.
 PERFORM api.finish_turn(cid,(j->>'token')::uuid,'',1,'Model unavailable');
 SELECT status INTO v FROM api.conversations WHERE id=cid;
 IF v<>'failed' THEN RAISE EXCEPTION 'Failure was not persisted'; END IF;
 PERFORM api.control_conversation(cid,'start');
 j:=api.claim_turn();
 PERFORM api.finish_turn(cid,(j->>'token')::uuid,'Second response',11);
 SELECT status,turn_count INTO v,n FROM api.conversations WHERE id=cid;
 IF v<>'completed' OR n<>2 THEN RAISE EXCEPTION 'Incorrect completion'; END IF;
 SELECT count(*) INTO n FROM api.messages WHERE conversation_id=cid;
 IF n<>3 THEN RAISE EXCEPTION 'Incorrect message count'; END IF;
 IF EXISTS (SELECT 1 FROM api.jobs WHERE conversation_id=cid) THEN RAISE EXCEPTION 'Completed job remains'; END IF;
 -- Public and worker APIs have separate capabilities.
 IF has_function_privilege('web_user','api.claim_turn()','EXECUTE') THEN RAISE EXCEPTION 'Worker RPC exposed'; END IF;
 IF has_table_privilege('web_user','api.messages','INSERT') THEN RAISE EXCEPTION 'Raw message writes exposed'; END IF;
 IF has_table_privilege('web_user','api.jobs','SELECT') THEN RAISE EXCEPTION 'Jobs exposed'; END IF;
 IF has_function_privilege('worker_user','api.delete_conversation(uuid)','EXECUTE') THEN RAISE EXCEPTION 'Worker can delete rooms'; END IF;
 PERFORM api.delete_conversation(cid);
 IF EXISTS(SELECT 1 FROM api.messages WHERE conversation_id=cid) THEN RAISE EXCEPTION 'Cascade failed'; END IF;
 RAISE NOTICE 'Database integration assertions passed';
END $$;
ROLLBACK;

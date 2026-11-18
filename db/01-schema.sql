CREATE SCHEMA api;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA api REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE api.model_profiles (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 name text NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
 provider text NOT NULL CHECK (provider IN ('ollama','openai')),
 model text NOT NULL CHECK (length(model) BETWEEN 1 AND 120),
 temperature numeric NOT NULL DEFAULT 0.7 CHECK (temperature BETWEEN 0 AND 2),
 max_tokens integer NOT NULL DEFAULT 160 CHECK (max_tokens BETWEEN 32 AND 512),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE api.scenarios (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 title text NOT NULL CHECK (length(title) BETWEEN 1 AND 100),
 topic text NOT NULL CHECK (length(topic) BETWEEN 1 AND 3000),
 instructions text NOT NULL DEFAULT '' CHECK (length(instructions) <= 2000),
 rounds integer NOT NULL DEFAULT 3 CHECK (rounds BETWEEN 1 AND 20),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE api.participants (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 scenario_id uuid NOT NULL REFERENCES api.scenarios ON DELETE CASCADE,
 name text NOT NULL CHECK (length(name) BETWEEN 1 AND 50),
 personality text NOT NULL CHECK (personality IN ('analyst','skeptic','optimist','pragmatist','mediator','visionary','custom')),
 stance text NOT NULL DEFAULT '' CHECK (length(stance) <= 1000),
 custom_prompt text NOT NULL DEFAULT '' CHECK (length(custom_prompt) <= 1500),
 color text NOT NULL DEFAULT 'violet' CHECK (color IN ('violet','teal','amber','rose','blue','lime')),
 position integer NOT NULL CHECK (position BETWEEN 0 AND 5),
 model_profile_id uuid NOT NULL REFERENCES api.model_profiles,
 UNIQUE(scenario_id, position)
);
CREATE TABLE api.conversations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 title text NOT NULL,
 config jsonb NOT NULL,
 status text NOT NULL DEFAULT 'idle' CHECK (status IN ('idle','queued','running','paused','completed','failed')),
 turn_count integer NOT NULL DEFAULT 0,
 error text,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE api.messages (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 conversation_id uuid NOT NULL REFERENCES api.conversations ON DELETE CASCADE,
 sequence integer NOT NULL,
 kind text NOT NULL CHECK (kind IN ('agent','user')),
 speaker text NOT NULL,
 color text NOT NULL DEFAULT 'blue',
 content text NOT NULL CHECK (length(content) BETWEEN 1 AND 12000),
 model text,
 duration_ms integer,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(conversation_id, sequence)
);
CREATE INDEX messages_conversation ON api.messages(conversation_id, sequence);
CREATE TABLE api.jobs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 conversation_id uuid NOT NULL UNIQUE REFERENCES api.conversations ON DELETE CASCADE,
 state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','running')),
 lease_token uuid,
 leased_until timestamptz,
 created_at timestamptz NOT NULL DEFAULT now()
);

-- All browser writes go through validated transactions. No table writes are granted.
CREATE FUNCTION api.save_model(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = api, pg_temp AS $$
DECLARE result uuid;
BEGIN
 INSERT INTO model_profiles(name,provider,model,temperature,max_tokens)
 VALUES (trim(p_data->>'name'),p_data->>'provider',trim(p_data->>'model'),
 coalesce((p_data->>'temperature')::numeric,0.7),coalesce((p_data->>'max_tokens')::integer,160))
 RETURNING id INTO result;
 RETURN result;
END $$;

CREATE FUNCTION api.save_scenario(p_data jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = api, pg_temp AS $$
DECLARE result uuid; member jsonb; idx integer := 0;
BEGIN
 IF jsonb_typeof(p_data->'participants') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'participants') NOT BETWEEN 2 AND 6 THEN
  RAISE EXCEPTION 'Choose between 2 and 6 participants';
 END IF;
 INSERT INTO scenarios(title,topic,instructions,rounds)
 VALUES(trim(p_data->>'title'),trim(p_data->>'topic'),coalesce(p_data->>'instructions',''),coalesce((p_data->>'rounds')::integer,3)) RETURNING id INTO result;
 FOR member IN SELECT * FROM jsonb_array_elements(p_data->'participants') LOOP
  INSERT INTO participants(scenario_id,name,personality,stance,custom_prompt,color,position,model_profile_id)
  VALUES(result,trim(member->>'name'),member->>'personality',coalesce(member->>'stance',''),coalesce(member->>'custom_prompt',''),
  coalesce(member->>'color','violet'),idx,(member->>'model_profile_id')::uuid);
  idx := idx+1;
 END LOOP;
 RETURN result;
END $$;

CREATE FUNCTION api.create_conversation(p_scenario_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = api, pg_temp AS $$
DECLARE s scenarios; members jsonb; result uuid;
BEGIN
 SELECT * INTO STRICT s FROM scenarios WHERE id=p_scenario_id;
 SELECT jsonb_agg(jsonb_build_object('name',p.name,'personality',p.personality,'stance',p.stance,'custom_prompt',p.custom_prompt,
 'color',p.color,'model',jsonb_build_object('provider',m.provider,'model',m.model,'temperature',m.temperature,'max_tokens',m.max_tokens)) ORDER BY p.position)
 INTO members FROM participants p JOIN model_profiles m ON m.id=p.model_profile_id WHERE p.scenario_id=s.id;
 IF jsonb_array_length(members) NOT BETWEEN 2 AND 6 OR members IS NULL THEN RAISE EXCEPTION 'Scenario needs 2–6 participants'; END IF;
 INSERT INTO conversations(title,config) VALUES(s.title,jsonb_build_object('topic',s.topic,'instructions',s.instructions,'rounds',s.rounds,'participants',members)) RETURNING id INTO result;
 RETURN result;
END $$;

CREATE FUNCTION api.control_conversation(p_id uuid, p_action text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = api, pg_temp AS $$
DECLARE c conversations;
BEGIN
 SELECT * INTO STRICT c FROM conversations WHERE id=p_id FOR UPDATE;
 IF p_action='pause' THEN
  IF c.status IN ('queued','running') THEN
   UPDATE conversations SET status='paused', updated_at=now() WHERE id=p_id;
   DELETE FROM jobs WHERE conversation_id=p_id;
  END IF;
 ELSIF p_action='start' THEN
  IF c.status IN ('idle','paused','failed') THEN
   IF c.turn_count >= (c.config->>'rounds')::integer * jsonb_array_length(c.config->'participants') THEN
    RAISE EXCEPTION 'Conversation has finished';
   END IF;
   UPDATE conversations SET status='queued',error=NULL,updated_at=now() WHERE id=p_id;
   INSERT INTO jobs(conversation_id) VALUES(p_id) ON CONFLICT(conversation_id) DO NOTHING;
  END IF;
 ELSE RAISE EXCEPTION 'Unknown action'; END IF;
END $$;

CREATE FUNCTION api.post_message(p_id uuid, p_content text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = api, pg_temp AS $$
BEGIN
 PERFORM 1 FROM conversations WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Conversation not found'; END IF;
 IF length(trim(p_content)) NOT BETWEEN 1 AND 4000 OR p_content IS NULL THEN RAISE EXCEPTION 'Message must be 1–4000 characters'; END IF;
 INSERT INTO messages(conversation_id,sequence,kind,speaker,content)
 SELECT p_id,coalesce(max(sequence),0)+1,'user','You',trim(p_content) FROM messages WHERE conversation_id=p_id;
 UPDATE conversations SET updated_at=now() WHERE id=p_id;
END $$;

CREATE FUNCTION api.delete_conversation(p_id uuid) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = api, pg_temp AS $$
 DELETE FROM conversations WHERE id=p_id;
$$;

-- Claim and commit a single turn. Leases recover after a worker crash.
-- Lock ordering is always conversation then job, including concurrent UI actions.
CREATE FUNCTION api.claim_turn() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = api, pg_temp AS $$
DECLARE c conversations; j jobs; token uuid; history jsonb;
BEGIN
 SELECT cv.* INTO c FROM conversations cv
 WHERE cv.status IN ('queued','running') AND EXISTS (
  SELECT 1 FROM jobs WHERE conversation_id=cv.id AND (state='pending' OR leased_until<now()))
 ORDER BY cv.updated_at FOR UPDATE SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 SELECT * INTO j FROM jobs WHERE conversation_id=c.id FOR UPDATE;
 IF j.id IS NULL OR (j.state='running' AND j.leased_until>=now()) THEN RETURN NULL; END IF;
 token := gen_random_uuid();
 UPDATE jobs SET state='running',lease_token=token,leased_until=now()+interval '5 minutes' WHERE id=j.id;
 UPDATE conversations SET status='running',updated_at=now() WHERE id=c.id;
 SELECT coalesce(jsonb_agg(to_jsonb(recent) ORDER BY sequence),'[]'::jsonb) INTO history
 FROM (SELECT sequence,kind,speaker,content FROM messages WHERE conversation_id=c.id ORDER BY sequence DESC LIMIT 24) recent;
 RETURN jsonb_build_object('id',c.id,'token',token,'turn',c.turn_count,'config',c.config,'history',history);
END $$;

CREATE FUNCTION api.finish_turn(p_id uuid,p_token uuid,p_content text,p_duration_ms integer,p_error text DEFAULT NULL) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = api, pg_temp AS $$
DECLARE c conversations; j jobs; member jsonb; count integer;
BEGIN
 SELECT * INTO c FROM conversations WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 SELECT * INTO j FROM jobs WHERE conversation_id=p_id FOR UPDATE;
 IF j.lease_token IS DISTINCT FROM p_token OR j.leased_until < now() OR c.status <> 'running' THEN RETURN false; END IF;
 IF p_error IS NOT NULL THEN
  UPDATE conversations SET status='failed',error=left(p_error,1000),updated_at=now() WHERE id=p_id;
  DELETE FROM jobs WHERE id=j.id;
  RETURN true;
 END IF;
 IF p_content IS NULL OR length(trim(p_content)) NOT BETWEEN 1 AND 12000 THEN RAISE EXCEPTION 'Empty or oversized model response'; END IF;
 member := (c.config->'participants')->(c.turn_count % jsonb_array_length(c.config->'participants'));
 INSERT INTO messages(conversation_id,sequence,kind,speaker,color,content,model,duration_ms)
 SELECT p_id,coalesce(max(sequence),0)+1,'agent',member->>'name',member->>'color',p_content,member->'model'->>'model',p_duration_ms
 FROM messages WHERE conversation_id=p_id;
 count := c.turn_count+1;
 IF count >= (c.config->>'rounds')::integer * jsonb_array_length(c.config->'participants') THEN
  UPDATE conversations SET turn_count=count,status='completed',updated_at=now() WHERE id=p_id;
  DELETE FROM jobs WHERE id=j.id;
 ELSE
  UPDATE conversations SET turn_count=count,status='queued',updated_at=now() WHERE id=p_id;
  UPDATE jobs SET state='pending',lease_token=NULL,leased_until=NULL WHERE id=j.id;
 END IF;
 RETURN true;
END $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
GRANT USAGE ON SCHEMA api TO web_user,worker_user;
GRANT SELECT ON api.scenarios,api.participants,api.model_profiles,api.conversations,api.messages TO web_user;
GRANT EXECUTE ON FUNCTION api.save_model(jsonb), api.save_scenario(jsonb),api.create_conversation(uuid),api.control_conversation(uuid,text),api.post_message(uuid,text),api.delete_conversation(uuid) TO web_user;
GRANT EXECUTE ON FUNCTION api.claim_turn(),api.finish_turn(uuid,uuid,text,integer,text) TO worker_user;

-- Idempotent upgrade for existing named volumes; old transcripts/config snapshots stay intact.
BEGIN;
UPDATE api.model_profiles
SET name=CASE WHEN id='10000000-0000-0000-0000-000000000001' THEN 'Qwen · debate / balanced' ELSE 'Qwen · debate / expressive' END,
    model='qwen2.5:3b',temperature=CASE WHEN id='10000000-0000-0000-0000-000000000001' THEN 0.7 ELSE 0.85 END,max_tokens=256
WHERE id IN ('10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002')
  AND provider='ollama' AND model='qwen2.5:0.5b';
-- Replace only original seeded stances, leaving custom scenarios untouched.
UPDATE api.participants SET stance=CASE name
 WHEN 'Maya' THEN 'Support a permanent four-day workweek at full pay. Argue that fewer hours can improve output; oppose keeping the five-day default.'
 WHEN 'Theo' THEN 'Oppose a four-day workweek at full pay. Defend five-day coverage and challenge claims that the lost hours will pay for themselves.'
 WHEN 'Alex' THEN 'Reject a universal four-day policy and the unchanged five-day default. Defend an optional staggered schedule tied to service coverage; challenge both Maya and Theo.'
 WHEN 'Iris' THEN 'Support removing private cars from the city center. Defend pedestrian priority even if driving becomes less convenient.'
 WHEN 'Sam' THEN 'Oppose a blanket car ban. Defend vehicle access for residents and small businesses; challenge promised benefits and accessibility assumptions.'
 WHEN 'Kai' THEN 'Keep the core product proprietary. Defend paid licensing and challenge the claim that an open-source community will fund maintenance.'
 WHEN 'Nova' THEN 'Open-source the core product. Defend community ownership and challenge proprietary lock-in and licensing assumptions.' END
WHERE (scenario_id,name,stance) IN (
 ('20000000-0000-0000-0000-000000000001'::uuid,'Maya','Support a trial, but be specific about what success means.'),
 ('20000000-0000-0000-0000-000000000001'::uuid,'Theo','Challenge hidden costs and unsupported productivity assumptions.'),
 ('20000000-0000-0000-0000-000000000001'::uuid,'Alex','Find a workable compromise and identify shared goals.'),
 ('20000000-0000-0000-0000-000000000002'::uuid,'Iris','Advocate walkability and a long-term livable city.'),
 ('20000000-0000-0000-0000-000000000002'::uuid,'Sam','Focus on implementation costs and accessibility.'),
 ('20000000-0000-0000-0000-000000000003'::uuid,'Kai','Compare realistic business models and tradeoffs.'),
 ('20000000-0000-0000-0000-000000000003'::uuid,'Nova','Explore community-driven development and adoption.'));
CREATE OR REPLACE FUNCTION api.claim_turn() RETURNS jsonb
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

NOTIFY pgrst, 'reload schema';
COMMIT;

INSERT INTO api.model_profiles(id,name,provider,model,temperature,max_tokens) VALUES
 ('10000000-0000-0000-0000-000000000001','Qwen · tiny / balanced','ollama','qwen2.5:0.5b',0.65,160),
 ('10000000-0000-0000-0000-000000000002','Qwen · tiny / creative','ollama','qwen2.5:0.5b',0.9,160);
INSERT INTO api.scenarios(id,title,topic,instructions,rounds) VALUES
 ('20000000-0000-0000-0000-000000000001','The four-day workweek','Should a small software company adopt a four-day workweek without reducing pay?','Consider productivity, employee wellbeing, and customer coverage. End with a concrete recommendation.',3),
 ('20000000-0000-0000-0000-000000000002','A city without cars','Should a city pedestrianize its central district?','Discuss residents, accessibility, local businesses, and transport alternatives.',3),
 ('20000000-0000-0000-0000-000000000003','Open source or proprietary?','A bootstrapped developer is releasing a new productivity app. Should its source code be public?','Consider revenue, community, maintenance burden, and user trust.',3);
INSERT INTO api.participants(scenario_id,name,personality,stance,color,position,model_profile_id) VALUES
 ('20000000-0000-0000-0000-000000000001','Maya','optimist','Support a trial, but be specific about what success means.','teal',0,'10000000-0000-0000-0000-000000000002'),
 ('20000000-0000-0000-0000-000000000001','Theo','skeptic','Challenge hidden costs and unsupported productivity assumptions.','amber',1,'10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001','Alex','mediator','Find a workable compromise and identify shared goals.','violet',2,'10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002','Iris','visionary','Advocate walkability and a long-term livable city.','teal',0,'10000000-0000-0000-0000-000000000002'),
 ('20000000-0000-0000-0000-000000000002','Sam','pragmatist','Focus on implementation costs and accessibility.','amber',1,'10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000003','Kai','analyst','Compare realistic business models and tradeoffs.','blue',0,'10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000003','Nova','visionary','Explore community-driven development and adoption.','rose',1,'10000000-0000-0000-0000-000000000002');

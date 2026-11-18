"""Live PostgREST + worker + real model smoke test. No simulated LLM responses."""
import argparse
import json
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--url',default='http://127.0.0.1:8080')
parser.add_argument('--timeout',type=int,default=900)
args=parser.parse_args()
base=args.url.rstrip('/')


def request(path,data=None):
    req=Request(base+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json'})
    with urlopen(req,timeout=30) as response:
        body=response.read()
        return json.loads(body) if body else None


def rpc(name,data):return request('/rest/rpc/'+name,data)

profiles=request('/rest/model_profiles?order=created_at.asc')
assert profiles, 'No seeded profiles'
models=request('/engine/models')
assert models.get('models'), 'Wait for model-init to finish downloading the default model'
for path in ['/rest/jobs','/rest/rpc/claim_turn']:
    try: request(path,{} if 'rpc' in path else None)
    except HTTPError as error: assert error.code in (401,403,404,405)
    else: raise AssertionError('Private worker resource exposed: '+path)
scenario=rpc('save_scenario',{'p_data':{'title':'Live smoke test','topic':'Should a team document its code?','rounds':3,'participants':[
    {'name':'Ada','personality':'analyst','stance':'Defend mandatory written documentation. Argue that tests cannot explain every design decision.','model_profile_id':profiles[0]['id']},
    {'name':'Lin','personality':'skeptic','stance':'Oppose mandatory written documentation. Defend executable tests and readable code instead; challenge documentation maintenance costs.','model_profile_id':profiles[0]['id']}]}})
room=rpc('create_conversation',{'p_scenario_id':scenario})
rpc('post_message',{'p_id':room,'p_content':'Please keep the discussion concise.'})
rpc('control_conversation',{'p_id':room,'p_action':'start'})
deadline=time.monotonic()+args.timeout
while time.monotonic()<deadline:
    c=request('/rest/conversations?id=eq.'+room)[0]
    if c['status']=='failed':raise AssertionError(c['error'])
    if c['status']=='completed':break
    time.sleep(2)
else:raise AssertionError('Timed out waiting for real inference')
messages=request('/rest/messages?conversation_id=eq.'+room+'&order=sequence.asc')
assert len(messages)==7 and [m['kind'] for m in messages]==['user']+['agent']*6
assert all(m['content'].strip() for m in messages)
assert [m['speaker'] for m in messages[1:]]==['Ada','Lin']*3
assert all(m['duration_ms'] is not None and m['model'] for m in messages[1:])
print(json.dumps({'conversation':room,'status':c['status'],'messages':len(messages),'models':[m['model'] for m in messages[1:]],'result':'PASS'},indent=2))
for message in messages:
    print(f"\n{message['speaker']}: {message['content']}")
print('Test conversation kept for inspection. Its messages are saved in PostgreSQL.')

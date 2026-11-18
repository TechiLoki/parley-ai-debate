import copy
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from debate import PERSONALITIES, Store, build_prompt, execute_turn, response_issues
from providers import OllamaProvider, OpenAICompatibleProvider, ProviderError, fetch_json


def sample_job():
    return {'id':'room','token':'lease','turn':0,'history':[], 'config':{
        'topic':'Should we adopt a four-day week?', 'instructions':'Be constructive.', 'rounds':2,
        'participants':[{'name':'Maya','personality':'optimist','stance':'Try it.','custom_prompt':'Be friendly.',
                         'color':'teal','model':{'provider':'ollama','model':'qwen2.5:0.5b','temperature':.7,'max_tokens':160}},
                        {'name':'Theo','personality':'skeptic','stance':'Measure costs.','custom_prompt':'',
                         'color':'amber','model':{'provider':'openai','model':'tiny','temperature':.4,'max_tokens':100}}]}}


class PromptTests(unittest.TestCase):
    def test_round_robin_and_distinct_model(self):
        job=sample_job()
        profile,prompt=build_prompt(job)
        self.assertEqual(profile['provider'],'ollama')
        self.assertIn('Maya',prompt[0]['content'])
        job['turn']=3
        profile,prompt=build_prompt(job)
        self.assertEqual(profile['provider'],'openai')
        self.assertIn('Round 2 of 2',prompt[1]['content'])
        self.assertIn('constructive skeptic',prompt[0]['content'])

    def test_history_and_scenario_in_prompt(self):
        job=sample_job(); job['history']=[{'speaker':'You','content':'Consider customer coverage.'}]
        _,prompt=build_prompt(job)
        self.assertIn('customer coverage',prompt[1]['content'])
        self.assertIn(job['config']['topic'],prompt[1]['content'])
        self.assertIn('Be friendly',prompt[0]['content'])

    def test_context_is_bounded(self):
        job=sample_job(); job['config']['topic']='x'*3000; job['config']['instructions']='y'*2000
        job['history']=[{'speaker':'Someone','content':'z'*12000} for _ in range(8)]
        _,prompt=build_prompt(job)
        self.assertLess(sum(len(m['content']) for m in prompt),12000)
        self.assertIn('Now respond as Maya',prompt[-1]['content'])

    def test_personality_catalog(self):
        self.assertEqual(len(PERSONALITIES),7)
        for personality in PERSONALITIES:
            job=sample_job();job['config']['participants'][0]['personality']=personality
            self.assertIn(PERSONALITIES[personality],build_prompt(job)[1][0]['content'])


    def test_previous_round_has_explicit_rebuttal_and_own_answer(self):
        job=sample_job();job['turn']=2
        job['history']=[
            {'kind':'agent','speaker':'Maya','content':'A shorter week prevents burnout.'},
            {'kind':'agent','speaker':'Theo','content':'Maya, fewer hours mean uncovered customer calls. Who will cover Fridays?'}]
        _,prompt=build_prompt(job)
        self.assertIn('YOUR REBUTTAL TARGET — Theo',prompt[1]['content'])
        self.assertIn('Who will cover Fridays?',prompt[1]['content'])
        self.assertIn('YOUR PREVIOUS ANSWER (do not repeat)',prompt[1]['content'])
        self.assertIn('A shorter week prevents burnout.',prompt[1]['content'])
        self.assertIn('Do not restart your opening statement',prompt[0]['content'])

    def test_empty_stances_get_opposing_positions(self):
        job=sample_job()
        for p in job['config']['participants']:p['stance']=''
        _,first=build_prompt(job);job['turn']=1;_,second=build_prompt(job)
        self.assertIn('Defend adopting',first[0]['content'])
        self.assertIn('Oppose adopting',second[0]['content'])

    def test_direct_challenge_takes_priority_over_unrelated_comment(self):
        job=sample_job();job['history']=[
            {'kind':'agent','speaker':'Theo','content':'Maya, how do you handle coverage?'},
            {'kind':'agent','speaker':'Alex','content':'I favor a different schedule.'}]
        _,prompt=build_prompt(job)
        self.assertIn('YOUR REBUTTAL TARGET — Theo',prompt[1]['content'])

    def test_already_answered_challenge_is_not_selected_again(self):
        job=sample_job();job['turn']=4
        job['history']=[
            {'kind':'agent','speaker':'Theo','content':'Maya, old question.'},
            {'kind':'agent','speaker':'Maya','content':'I answered that question.'},
            {'kind':'agent','speaker':'Alex','content':'A new problem with your argument.'}]
        _,prompt=build_prompt(job)
        self.assertIn('YOUR REBUTTAL TARGET — Alex',prompt[1]['content'])

    def test_quality_checks_detect_repetition_and_generic_agreement(self):
        job=sample_job();job['history']=[
            {'kind':'agent','speaker':'Maya','content':'A shorter week prevents burnout and boosts productivity.'},
            {'kind':'agent','speaker':'Theo','content':'Who covers the customer calls on Friday?'}]
        self.assertTrue(response_issues(job,'A shorter week prevents burnout and boosts productivity.'))
        self.assertTrue(response_issues(job,'I agree, Theo, we should consider the benefits.'))
        self.assertFalse(response_issues(job,'Theo, coverage does not require everyone to work the same days. Staggered shifts can cover Friday without a fifth day for each person. Why assume everyone takes Friday off?'))

    def test_last_round_does_not_force_consensus(self):
        job=sample_job();job['turn']=3
        _,prompt=build_prompt(job)
        self.assertIn('Do not manufacture a joint conclusion',prompt[1]['content'])


class ProviderTests(unittest.TestCase):
    @patch('providers.fetch_json')
    def test_ollama_cpu_payload(self,fetch):
        fetch.return_value={'message':{'content':' A real response. '}}
        profile,prompt=build_prompt(sample_job())
        self.assertEqual(OllamaProvider('http://ollama').generate(profile,prompt),'A real response.')
        args,kwargs=fetch.call_args
        self.assertEqual(args[0],'http://ollama/api/chat')
        self.assertEqual(args[1]['options']['num_gpu'],0)
        self.assertEqual(args[1]['options']['num_ctx'],4096)
        self.assertFalse(args[1]['stream'])

    @patch('providers.fetch_json')
    def test_compatible_payload_and_auth(self,fetch):
        fetch.return_value={'choices':[{'message':{'content':'Reply'}}]}
        profile,prompt=build_prompt(sample_job())
        provider=OpenAICompatibleProvider('http://local/v1/','secret')
        self.assertEqual(provider.generate(profile,prompt),'Reply')
        args,kwargs=fetch.call_args
        self.assertEqual(args[0],'http://local/v1/chat/completions')
        self.assertEqual(kwargs['headers']['Authorization'],'Bearer secret')
        self.assertEqual(args[1]['max_tokens'],160)

    @patch('providers.fetch_json')
    def test_empty_response_fails(self,fetch):
        fetch.return_value={'message':{'content':'   '}}
        with self.assertRaises(ProviderError): OllamaProvider('http://local').generate(*build_prompt(sample_job()))

    @patch('providers.fetch_json')
    def test_invalid_compatible_response(self,fetch):
        fetch.return_value={'choices':[]}
        with self.assertRaises(ProviderError): OpenAICompatibleProvider('http://local').generate(*build_prompt(sample_job()))

    @patch('providers.request.urlopen')
    def test_http_error_is_sanitized(self,urlopen):
        urlopen.side_effect=HTTPError('http://local',401,'secret',{},io.BytesIO(b'secret'))
        with self.assertRaises(ProviderError) as ctx: fetch_json('http://local')
        self.assertIn('401',str(ctx.exception));self.assertNotIn('secret',str(ctx.exception))

    @patch('providers.request.urlopen')
    def test_unreachable_service(self,urlopen):
        urlopen.side_effect=URLError('offline')
        with self.assertRaises(ProviderError): fetch_json('http://local')


class FakeStore:
    def finish(self,*args):self.result=args;return True

class FakeProvider:
    def generate(self,profile,prompt):return 'Generated answer'

class WorkerTests(unittest.TestCase):
    def test_commit_includes_lease(self):
        store=FakeStore();job=sample_job()
        self.assertTrue(execute_turn(store,{'ollama':FakeProvider()},job))
        self.assertEqual(store.result[0]['token'],'lease')
        self.assertEqual(store.result[1],'Generated answer')
        self.assertEqual(len(store.result),3)

    def test_provider_failure_is_persisted(self):
        class Broken:
            def generate(self,*args):raise ProviderError('Missing model')
        store=FakeStore();execute_turn(store,{'ollama':Broken()},sample_job())
        self.assertEqual(store.result[3],'Missing model')

    def test_unexpected_failure_is_sanitized(self):
        class Broken:
            def generate(self,*args):raise RuntimeError('sensitive details')
        store=FakeStore();execute_turn(store,{'ollama':Broken()},sample_job())
        self.assertNotIn('sensitive',store.result[3])

    @patch('debate.fetch_json')
    def test_store_rpc_contract(self,fetch):
        store=Store('http://rest:3000');job=sample_job()
        store.finish(job,'Answer',12)
        args,kwargs=fetch.call_args
        self.assertEqual(args[0],'http://rest:3000/rpc/finish_turn')
        self.assertEqual(args[1]['p_token'],'lease')
        self.assertIsNone(args[1]['p_error'])


    def test_repeated_reply_gets_one_targeted_rewrite(self):
        class Rewriter:
            def __init__(self):self.prompts=[]
            def generate(self,profile,prompt):
                self.prompts.append(prompt)
                return 'I agree with the general idea.' if len(self.prompts)==1 else 'Theo, you assume everyone takes Friday off. Staggered shifts avoid that gap. Why reject staggered coverage?'
        job=sample_job();job['history']=[{'kind':'agent','speaker':'Theo','content':'Who handles Friday?'}]
        store=FakeStore();provider=Rewriter()
        execute_turn(store,{'ollama':provider},job)
        self.assertEqual(len(provider.prompts),2)
        self.assertIn('Rewrite your reply',provider.prompts[1][-1]['content'])
        self.assertTrue(store.result[1].startswith('Theo,'))

    def test_persistent_nonresponse_fails_without_saving_a_bad_reply(self):
        job=sample_job();job['history']=[{'kind':'agent','speaker':'Theo','content':'Who handles Friday?'}]
        store=FakeStore();execute_turn(store,{'ollama':FakeProvider()},job)
        self.assertEqual(store.result[1],'')
        self.assertIn('did not address its opponent',store.result[3])

if __name__=='__main__':unittest.main()

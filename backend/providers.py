"""Small interchangeable HTTP adapters. Credentials remain in backend environment."""
import json
import os
from urllib import request, error


class ProviderError(RuntimeError):
    pass


def fetch_json(url, payload=None, headers=None, timeout=10):
    body = None if payload is None else json.dumps(payload).encode()
    req = request.Request(url, data=body, headers={'Content-Type': 'application/json', **(headers or {})})
    try:
        with request.urlopen(req, timeout=timeout) as response:
            return json.load(response)
    except error.HTTPError as exc:
        # Do not surface remote error bodies or authorization headers to the UI.
        raise ProviderError(f'Service returned HTTP {exc.code}. Check model name and provider configuration.') from None
    except (error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise ProviderError('Service unavailable, timed out, or returned invalid JSON. Check the container logs and provider address.') from None


class OllamaProvider:
    def __init__(self, base_url, timeout=120):
        self.base_url, self.timeout = base_url.rstrip('/'), timeout

    def generate(self, profile, messages):
        result = fetch_json(self.base_url + '/api/chat', {
            'model': profile['model'], 'messages': messages, 'stream': False,
            'keep_alive': '2m',
            'options': {'temperature': float(profile['temperature']),
                        'num_predict': int(profile['max_tokens']), 'num_ctx': 4096, 'num_gpu': 0},
        }, timeout=self.timeout)
        return validate_text(result.get('message', {}).get('content'))

    def models(self):
        return [item['name'] for item in fetch_json(self.base_url + '/api/tags').get('models', [])]


class OpenAICompatibleProvider:
    def __init__(self, base_url, api_key='', timeout=120):
        self.base_url, self.timeout = base_url.rstrip('/'), timeout
        self.headers = {'Authorization': f'Bearer {api_key}'} if api_key else {}

    def generate(self, profile, messages):
        result = fetch_json(self.base_url + '/chat/completions', {
            'model': profile['model'], 'messages': messages, 'stream': False,
            'temperature': float(profile['temperature']), 'max_tokens': int(profile['max_tokens']),
        }, headers=self.headers, timeout=self.timeout)
        try:
            content = result['choices'][0]['message']['content']
        except (KeyError, IndexError, TypeError):
            raise ProviderError('Provider returned an invalid chat completion.') from None
        return validate_text(content)


def validate_text(content):
    if not isinstance(content, str) or not content.strip():
        raise ProviderError('Model returned an empty response. Try another model or increase the token limit.')
    return content.strip()[:12000]


def configured_providers():
    timeout = int(os.getenv('LLM_TIMEOUT', '120'))
    return {
        'ollama': OllamaProvider(os.getenv('OLLAMA_URL', 'http://ollama:11434'), timeout),
        'openai': OpenAICompatibleProvider(os.getenv('OPENAI_BASE_URL', 'http://host.docker.internal:1234/v1'),
                                            os.getenv('OPENAI_API_KEY', ''), timeout),
    }

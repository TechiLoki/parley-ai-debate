"""Single sequential worker plus read-only health/model discovery HTTP endpoints."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
import threading
import time
from debate import Store, execute_turn
from providers import configured_providers, ProviderError

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
providers = configured_providers()
worker_state = {'connected': False, 'busy': False, 'last_error': None, 'last_poll': None}


def worker():
    store = Store(os.getenv('POSTGREST_URL', 'http://worker-rest:3000'))
    while True:
        try:
            job = store.claim()
            worker_state.update(connected=True, last_error=None, last_poll=time.time())
            if job:
                worker_state['busy'] = True
                execute_turn(store, providers, job)
            else:
                time.sleep(1)
        except Exception:
            worker_state.update(connected=False, last_error='Worker cannot reach the database API; retrying.')
            logging.exception('Worker iteration failed; leases allow recovery')
            time.sleep(3)
        finally:
            worker_state['busy'] = False


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        status = 200
        if path == '/health':
            result = {'ok': True, 'worker': worker_state}
        elif path == '/models':
            try:
                result = {'models': providers['ollama'].models(), 'ready': True}
            except ProviderError:
                result = {'models': [], 'ready': False, 'message': 'Ollama is starting or the model is still downloading.'}
        else:
            status, result = 404, {'error': 'Not found'}
        body = json.dumps(result).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args): pass


if __name__ == '__main__':
    threading.Thread(target=worker, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', 8000), Handler).serve_forever()

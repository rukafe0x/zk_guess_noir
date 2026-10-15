#!/usr/bin/env python3

import json
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import os

class ProofHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            # Read the content length
            content_length = int(self.headers['Content-Length'])
            
            # Read the request body
            post_data = self.rfile.read(content_length)
            
            # Parse JSON data
            try:
                data = json.loads(post_data.decode('utf-8'))
                print(f"Received data: {data}")
            except json.JSONDecodeError as e:
                print(f"JSON decode error: {e}")
                self.send_error(400, "Invalid JSON")
                return
            
            # Save proof to file
            with open('proof.json', 'w') as f:
                json.dump(data, f)
            
            print(f"Proof saved to proof.json")
            
            # Call garaga command
            cmd = [
                '/home/kali/garaga/venv/bin/garaga',
                'calldata',
                '--system', 'groth16',
                '--vk', './verification_key.json',
                '--proof', 'proof.json',
                '--format', 'array'
            ]
            
            print(f"Running command: {' '.join(cmd)}")
            
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, check=True)
                output = result.stdout.strip()
                print(f"Garaga output: {output}")
                
                # Send response
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
                self.send_header('Access-Control-Allow-Headers', 'Content-Type')
                self.end_headers()
                
                # Send the output directly (it's already in the correct format)
                self.wfile.write(output.encode('utf-8'))
                
            except subprocess.CalledProcessError as e:
                print(f"Garaga error: {e.stderr}")
                self.send_error(500, f"Garaga execution failed: {e.stderr}")
                return
                
        except Exception as e:
            print(f"Error processing request: {e}")
            self.send_error(500, f"Internal server error: {e}")
    
    def do_OPTIONS(self):
        # Handle CORS preflight requests
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass

def main():
    port = 8080
    server_address = ('', port)
    httpd = HTTPServer(server_address, ProofHandler)
    
    print(f"Starting server on port {port}")
    print("Server is ready to receive requests...")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        httpd.shutdown()

if __name__ == '__main__':
    main()

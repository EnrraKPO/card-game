@echo off
rem Start the local AudioGen SFX server (loads the model once, stays warm).
rem First run downloads ~4GB of model weights from HuggingFace.
cd /d "%~dp0"
rem Avast intercepts HTTPS with its own cert; Python must trust it (certifi + Avast pem,
rem combined into ca_bundle.pem) or HuggingFace downloads fail with SSL errors.
set REQUESTS_CA_BUNDLE=%~dp0ca_bundle.pem
set SSL_CERT_FILE=%~dp0ca_bundle.pem
set CURL_CA_BUNDLE=%~dp0ca_bundle.pem
venv\Scripts\python.exe server.py %*
pause

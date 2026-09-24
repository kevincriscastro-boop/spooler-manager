"""
Smoke tests for the Gerenciador do Spooler HTTP API.

Roda contra a instancia LOCAL ja em execucao (SpoolerMonitor.ps1) e, nos
testes marcados com @pytest.mark.vps, contra o pacote publicado na VPS.
Nao inicia nem para nenhum processo - assume que o monitor local ja esta
rodando (o caso normal numa maquina com o app instalado).

Uso:
    pip install -r tools/requirements.txt
    pytest tools/tests -v                # so os testes locais
    pytest tools/tests -v -m vps         # so os que checam o pacote da VPS
    pytest tools/tests -v -m ""          # todos

Rodar isso ANTES de publicar uma nova versao (scp pro VPS) pega boa parte
dos bugs que ja escaparam pra producao essa semana (ex: caminho errado do
instalador dentro do zip, endpoint autenticado sem checar o token).
"""
import io
import json
import os
import pathlib
import zipfile

import pytest
import requests

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG_FILE = REPO_ROOT / "dist_spooler" / "app" / "config.json"


def _vps_url_from_config():
    # config.json fica fora do Git (tem o endereco real do servidor) - sem ele
    # e sem SPOOLER_VPS_URL, os testes marcados vps sao pulados.
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8")).get("update_base_url")
    except (OSError, ValueError):
        return None


LOCAL_BASE_URL = os.environ.get("SPOOLER_LOCAL_URL", "http://127.0.0.1:8989")
VPS_BASE_URL = os.environ.get("SPOOLER_VPS_URL") or _vps_url_from_config()
TIMEOUT = 8

requires_vps_url = pytest.mark.skipif(
    not VPS_BASE_URL, reason="sem SPOOLER_VPS_URL nem dist_spooler/app/config.json"
)


# --------------------------------------------------------------------------
# /api/health - publico, usado pela Frota e pela tela inicial
# --------------------------------------------------------------------------

def test_health_returns_expected_fields():
    resp = requests.get(f"{LOCAL_BASE_URL}/api/health", timeout=TIMEOUT)
    assert resp.status_code == 200
    data = resp.json()
    for campo in ["spooler_status", "current_queue", "hostname", "printers", "version", "stats"]:
        assert campo in data, f"campo '{campo}' ausente em /api/health"


def test_health_has_cors_header():
    resp = requests.get(f"{LOCAL_BASE_URL}/api/health", timeout=TIMEOUT)
    assert resp.headers.get("Access-Control-Allow-Origin") == "*"


# --------------------------------------------------------------------------
# /api/machine-info - publico, specs de hardware via WMI
# --------------------------------------------------------------------------

def test_machine_info_returns_expected_fields():
    resp = requests.get(f"{LOCAL_BASE_URL}/api/machine-info", timeout=TIMEOUT)
    assert resp.status_code == 200
    data = resp.json()
    for campo in ["manufacturer", "model", "serial", "os_caption"]:
        assert campo in data, f"campo '{campo}' ausente em /api/machine-info"


# --------------------------------------------------------------------------
# /photos/ - serve a foto do equipamento, com protecao contra path traversal
# --------------------------------------------------------------------------

def test_photos_route_blocks_path_traversal():
    resp = requests.get(f"{LOCAL_BASE_URL}/photos/..%2f..%2fWindows%2fwin.ini", timeout=TIMEOUT)
    # http.sys geralmente já barra o ".." codificado com 403 antes de chegar
    # no nosso código; se algum dia isso mudar e passar, o GetFileName do
    # SpoolerMonitor.ps1 ainda descarta qualquer parte de diretório e
    # devolve 404. De qualquer forma, nunca pode ser 200.
    assert resp.status_code in (403, 404)


def test_photos_route_404_for_unknown_file():
    resp = requests.get(f"{LOCAL_BASE_URL}/photos/maquina-que-nao-existe-123.png", timeout=TIMEOUT)
    assert resp.status_code == 404


# --------------------------------------------------------------------------
# /api/check-update - publico, so leitura (nunca deve instalar nada sozinho)
# --------------------------------------------------------------------------

def test_check_update_returns_expected_fields():
    resp = requests.get(f"{LOCAL_BASE_URL}/api/check-update", timeout=TIMEOUT)
    assert resp.status_code == 200
    data = resp.json()
    for campo in ["current_version", "latest_version", "update_available"]:
        assert campo in data, f"campo '{campo}' ausente em /api/check-update"


# --------------------------------------------------------------------------
# Endpoints autenticados - devem recusar requisicoes sem token (isso e o
# que impede qualquer um na rede local de reiniciar/atualizar sem senha)
# --------------------------------------------------------------------------

@pytest.mark.parametrize("path,method", [
    ("/api/status", "GET"),
    ("/api/machines", "GET"),
    ("/api/force-restart", "POST"),
    ("/api/force-update", "POST"),
])
def test_authenticated_endpoints_reject_without_token(path, method):
    resp = requests.request(method, f"{LOCAL_BASE_URL}{path}", timeout=TIMEOUT)
    assert resp.status_code == 401, f"{method} {path} deveria exigir autenticação"


def test_login_with_wrong_password_fails():
    resp = requests.post(
        f"{LOCAL_BASE_URL}/api/login",
        json={"username": "admin", "password_hash": "0" * 64},
        timeout=TIMEOUT,
    )
    assert resp.status_code == 401
    assert resp.json().get("success") is False


# --------------------------------------------------------------------------
# Regressao: o zip publicado precisa ter Instalar.bat na RAIZ (nao dentro de
# uma pasta "dist_spooler/"), senao o AtualizarAgora.ps1 (e o install.ps1)
# nao acham o instalador e a atualizacao automatica falha silenciosamente -
# foi exatamente isso que quebrou a atualizacao das 11h/15h em 22/09/2026.
# --------------------------------------------------------------------------

@pytest.mark.vps
@requires_vps_url
def test_published_zip_has_installer_at_root():
    resp = requests.get(f"{VPS_BASE_URL}/dist_spooler.zip", timeout=30)
    assert resp.status_code == 200
    with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
        names = zf.namelist()
    assert "Instalar.bat" in names, (
        "Instalar.bat não está na raiz do zip publicado - o AtualizarAgora.ps1 "
        "vai falhar silenciosamente ao tentar aplicar essa versão "
        "(mesma causa do bug de 22/09/2026)"
    )


# --------------------------------------------------------------------------
# config.json: o endereco do servidor de atualizacao saiu do codigo. Se ele
# nao chegar nas maquinas, elas atualizam UMA vez e depois nunca mais acham a
# VPS - por isso os dois lados (zip publicado e instalador) sao checados.
# --------------------------------------------------------------------------

@pytest.mark.vps
@requires_vps_url
def test_published_zip_has_config_with_update_url():
    resp = requests.get(f"{VPS_BASE_URL}/dist_spooler.zip", timeout=30)
    assert resp.status_code == 200
    with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
        assert "app/config.json" in zf.namelist(), "zip publicado sem app/config.json"
        config = json.loads(zf.read("app/config.json").decode("utf-8-sig"))
    assert config.get("update_base_url"), "app/config.json publicado sem update_base_url"


def test_installer_copies_config_on_update():
    # No ramo de atualizacao (maquina ja instalada) o Instalar.bat copia uma
    # lista fixa de arquivos - o config.json tem que estar nela.
    bat = (REPO_ROOT / "dist_spooler" / "Instalar.bat").read_text(encoding="utf-8-sig")
    ramo_atualizacao = bat.split('if exist "%TARGET_DIR%\\data.json" (', 1)[1].split(") else (", 1)[0]
    assert 'copy /y "app\\config.json"' in ramo_atualizacao


@pytest.mark.vps
@requires_vps_url
def test_vps_version_endpoint_is_reachable():
    resp = requests.get(f"{VPS_BASE_URL}/VERSION", timeout=TIMEOUT)
    assert resp.status_code == 200
    assert resp.text.strip(), "VERSION publicado na VPS veio vazio"

"""
Gera os prints do painel usados no README (docs/screenshots/).

Abre o dashboard.html do repositorio num Chromium controlado pelo Playwright
e responde TODAS as chamadas de API com dados ficticios - nenhuma maquina
real e consultada e nenhum dado real aparece nas imagens. As fotos usadas
sao as de produto de photos-by-model/ (sem dado de nenhum ambiente).

Uso:
    pip install playwright && python -m playwright install chromium
    python tools/gerar_prints_readme.py
"""
import json
import pathlib
import re
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_DIR = REPO_ROOT / "dist_spooler" / "app"
OUT_DIR = REPO_ROOT / "docs" / "screenshots"
BASE = "http://painel.exemplo:8989"
VERSAO = "2026.09.24.4"

FOTOS_POR_HOST = {
    "PC-ADMIN01": "Dell_OptiPlex_7050.png",
    "PC-RECEPCAO01": "Dell_OptiPlex_3020.png",
    "PC-FINANCEIRO02": "Dell_OptiPlex_7050.png",
    "NB-VENDAS03": "Dell_Vostro_3401.png",
}
OFFLINE = {"PC-ESTOQUE04"}

MAQUINAS = [
    {"id": "a1", "name": "Recepção", "host": "PC-RECEPCAO01"},
    {"id": "a2", "name": "Financeiro", "host": "PC-FINANCEIRO02"},
    {"id": "a3", "name": "Vendas - Notebook", "host": "NB-VENDAS03"},
    {"id": "a4", "name": "Estoque", "host": "PC-ESTOQUE04"},
]

HISTORICO = [
    {"timestamp": "24/09/2026 10:42:15", "type": "Automático", "reason": "Fila travada há mais de 5 minutos",
     "printers": "Impressora Recepção", "cleaned": 3},
    {"timestamp": "23/09/2026 16:08:51", "type": "Manual", "reason": "Reinício forçado pelo painel",
     "printers": "Todas", "cleaned": 1},
    {"timestamp": "23/09/2026 09:15:02", "type": "Automático", "reason": "Fila travada há mais de 5 minutos",
     "printers": "Etiquetas Expedição", "cleaned": 7},
    {"timestamp": "22/09/2026 14:30:27", "type": "Automático", "reason": "Fila travada há mais de 5 minutos",
     "printers": "Impressora Financeiro", "cleaned": 2},
]


def health(host):
    dados = {
        "PC-ADMIN01": (["Impressora Recepção", "Etiquetas Expedição"], 0, 182.4, 237.9, (4, 1, 13)),
        "PC-RECEPCAO01": (["Impressora Recepção"], 0, 96.2, 237.9, (6, 0, 18)),
        "PC-FINANCEIRO02": (["Impressora Financeiro", "Microsoft Print to PDF"], 2, 21.7, 237.9, (2, 3, 9)),
        "NB-VENDAS03": (["Impressora Vendas"], 0, 12.1, 118.6, (1, 0, 2)),
    }[host]
    impressoras, fila, livre, total, (auto, manual, limpos) = dados
    return {
        "spooler_status": "Running",
        "current_queue": fila,
        "hostname": host,
        "printers": impressoras,
        "anydesk_id": "123456789",
        "version": VERSAO,
        "stats": {"restarts_auto": auto, "restarts_manual": manual, "total_prints_cleaned": limpos},
        "last_event": HISTORICO[0] if host == "PC-ADMIN01" else None,
        "disk_free_gb": livre,
        "disk_total_gb": total,
    }


def machine_info(host):
    modelo = FOTOS_POR_HOST.get(host, "Dell_OptiPlex_7050.png")[:-4].split("_", 1)
    return {
        "manufacturer": modelo[0],
        "model": modelo[1].replace("_", " "),
        "serial": "EXEMPLO" + host[-2:],
        "os_caption": "Microsoft Windows 11 Pro",
        "os_version": "10.0.26100",
        "ram_gb": 16,
    }


def responder(route):
    url = route.request.url
    m = re.match(r"https?://([^:/]+)(?::\d+)?(/[^?]*)", url)
    # O navegador normaliza o host da URL para minusculas.
    host, path = m.group(1).upper(), m.group(2)
    host = "PC-ADMIN01" if host == "PAINEL.EXEMPLO" else host

    def json_resp(obj, status=200):
        route.fulfill(status=status, content_type="application/json", body=json.dumps(obj),
                      headers={"Access-Control-Allow-Origin": "*"})

    if host in OFFLINE:
        return route.abort()
    if path in ("/", "/index.html"):
        return route.fulfill(content_type="text/html; charset=utf-8",
                             body=(APP_DIR / "dashboard.html").read_bytes())
    if path.startswith("/photos/"):
        foto = FOTOS_POR_HOST.get(host)
        if not foto:
            return route.fulfill(status=404, body="")
        return route.fulfill(content_type="image/png", body=(APP_DIR / "photos-by-model" / foto).read_bytes(),
                             headers={"Access-Control-Allow-Origin": "*"})
    if path == "/api/model-photo":
        q = parse_qs(urlparse(url).query)
        chave = f"{q.get('manufacturer', [''])[0]}_{q.get('model', [''])[0]}".replace(" ", "_").replace("Inc._", "")
        arquivo = APP_DIR / "photos-by-model" / f"{chave}.png"
        if not arquivo.exists():
            return route.fulfill(status=404, body="")
        return route.fulfill(content_type="image/png", body=arquivo.read_bytes())
    if path == "/api/health":
        return json_resp(health(host))
    if path == "/api/machine-info":
        return json_resp(machine_info(host))
    if path == "/api/check-update":
        return json_resp({"current_version": VERSAO, "latest_version": VERSAO, "update_available": False})
    if path == "/api/status":
        h = health(host)
        return json_resp({"stats": h["stats"], "current_queue": 0, "spooler_status": "Running", "history": HISTORICO})
    if path == "/api/machines":
        return json_resp({"machines": MAQUINAS})
    if path == "/api/login":
        return json_resp({"success": True, "token": "token-exemplo"})
    if re.search(r"\.(ico|png)$", path):
        arquivo = APP_DIR / path.lstrip("/")
        if arquivo.exists():
            return route.fulfill(body=arquivo.read_bytes())
    return route.fulfill(status=404, body="")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()

        def nova_pagina(logado):
            ctx = browser.new_context(viewport={"width": 1280, "height": 860}, device_scale_factor=1.5,
                                      color_scheme="dark", locale="pt-BR")
            # Qualquer requisicao (inclusive fontes externas) passa pelo roteador
            # ficticio - se nao for tratada ali, vira 404 e nada sai pra rede.
            ctx.route("**/*", responder)
            if logado:
                ctx.add_init_script("localStorage.setItem('spooler_token', 'token-exemplo')")
            page = ctx.new_page()
            page.goto(BASE + "/")
            return page

        page = nova_pagina(logado=False)
        page.wait_for_selector("#home-photo", state="visible")
        page.wait_for_timeout(800)
        page.screenshot(path=OUT_DIR / "tela-inicial.png", full_page=True)

        page = nova_pagina(logado=True)
        page.wait_for_selector("#history-rows tr td >> text=Automático")
        page.wait_for_selector("#dash-photo", state="visible")
        page.wait_for_timeout(800)
        page.screenshot(path=OUT_DIR / "este-computador.png", full_page=True)

        page.evaluate("switchTab('frota')")
        page.wait_for_selector("#status-a4 >> text=Offline", timeout=15000)
        page.wait_for_selector("#photo-a3", state="visible")
        page.wait_for_timeout(800)
        page.screenshot(path=OUT_DIR / "frota.png", full_page=True)

        browser.close()
    print(f"Prints salvos em {OUT_DIR}")


if __name__ == "__main__":
    main()

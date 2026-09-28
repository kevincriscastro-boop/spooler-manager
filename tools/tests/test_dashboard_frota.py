"""
Testes do painel no navegador (Playwright) com a API simulada do
gerar_prints_readme.py: ultima leitura guardada no monitor, filtros da
Frota, edicao de maquina e configuracoes do monitor (inclusive aplicar em
toda a Frota). Em todos, o painel nao pode gerar erro de JavaScript.
"""
import copy
import sys
from pathlib import Path

import pytest

playwright = pytest.importorskip("playwright.sync_api")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gerar_prints_readme as painel  # noqa: E402

MAQUINAS_ORIGINAIS = copy.deepcopy(painel.MAQUINAS)
CONFIG_ORIGINAL = copy.deepcopy(painel.CONFIG)


@pytest.fixture
def pagina():
    painel.MAQUINAS[:] = copy.deepcopy(MAQUINAS_ORIGINAIS)
    painel.CONFIG.clear(); painel.CONFIG.update(copy.deepcopy(CONFIG_ORIGINAL))
    painel.ENVIOS.clear()
    with playwright.sync_playwright() as p:
        try:
            browser = p.chromium.launch()
        except Exception as e:
            pytest.skip(f"Chromium indisponivel: {e}")
        ctx = browser.new_context()
        ctx.route("**/*", painel.responder)
        ctx.add_init_script("localStorage.setItem('spooler_token', 'token-exemplo');")
        page = ctx.new_page()
        erros = []
        page.on("pageerror", lambda e: erros.append(str(e)))
        page.on("dialog", lambda d: d.accept("admin") if d.type == "prompt" else d.accept())
        yield page
        assert erros == [], f"erros de JavaScript no painel: {erros}"
        browser.close()


def abrir_frota(page):
    page.goto(painel.BASE + "/")
    page.evaluate("switchTab('frota')")
    page.wait_for_selector("#status-a4 >> text=Offline", timeout=15000)
    for i in (1, 2, 3):
        page.wait_for_selector(f"#status-a{i} >> text=Spooler Ativo", timeout=15000)


def visiveis(page):
    return page.evaluate("[...document.querySelectorAll('#machines-grid .machine-card')].filter(c => c.style.display !== 'none').map(c => c.id)")


def test_maquina_offline_usa_leitura_guardada_no_monitor(pagina):
    # Nada no navegador: a ultima leitura vem do data.json do monitor.
    painel.MAQUINAS[3]["last_specs"] = {"manufacturer": "Dell Inc.", "model": "OptiPlex 3020", "serial": "EXEMPLO04",
                                        "os_caption": "Microsoft Windows 10 Pro"}
    painel.MAQUINAS[3]["last_seen"] = "2026-09-20T10:00:00"
    abrir_frota(pagina)
    assert "OptiPlex 3020" in pagina.inner_text("#specs-a4")
    # E as maquinas online mandam a leitura delas para o monitor guardar.
    pagina.wait_for_function("() => true")
    caminhos = [e["path"] for e in painel.ENVIOS]
    assert "/api/machines/cache" in caminhos


def test_filtros_da_frota(pagina):
    abrir_frota(pagina)
    pagina.select_option("#filtro-situacao", "offline")
    assert visiveis(pagina) == ["machine-a4"]
    assert pagina.inner_text("#filtro-contagem") == "1 de 4 máquina(s)"

    pagina.select_option("#filtro-situacao", "")
    pagina.select_option("#filtro-modelo", "Dell OptiPlex 7050")
    assert visiveis(pagina) == ["machine-a2"]

    pagina.select_option("#filtro-modelo", "")
    pagina.fill("#filtro-busca", "vendas")
    assert visiveis(pagina) == ["machine-a3"]
    pagina.fill("#filtro-busca", "Impressora Financeiro")  # busca tambem pelas impressoras
    assert visiveis(pagina) == ["machine-a2"]


def test_editar_maquina(pagina):
    abrir_frota(pagina)
    pagina.click("#machine-a1 >> text=Editar")
    pagina.fill("#editar-nome", "Recepção Térreo")
    pagina.click("#modal-editar >> text=Salvar")
    pagina.wait_for_selector("#machine-a1 >> text=Recepção Térreo")
    envio = [e for e in painel.ENVIOS if e["path"] == "/api/machines/update"][-1]
    assert envio["body"] == {"id": "a1", "name": "Recepção Térreo", "host": "PC-RECEPCAO01"}


def test_configuracoes_nesta_maquina_e_na_frota(pagina):
    pagina.goto(painel.BASE + "/")
    pagina.wait_for_function("() => document.getElementById('cfg-limiar').value === '5'")
    assert pagina.input_value("#cfg-horas") == "11, 15"

    pagina.fill("#cfg-limiar", "10")
    pagina.fill("#cfg-horas", "9, 14")
    pagina.click("text=Salvar nesta máquina")
    pagina.wait_for_selector("#cfg-resultado >> text=salvas nesta máquina")
    assert painel.CONFIG == {"stuck_threshold_minutes": 10, "check_interval_seconds": 30, "update_hours": [9, 14]}

    pagina.fill("#cfg-horas", "25")
    pagina.click("text=Salvar nesta máquina")
    pagina.wait_for_selector("#cfg-resultado >> text=entre 0 e 23")

    pagina.fill("#cfg-horas", "8")
    pagina.click("text=Aplicar em toda a Frota")
    pagina.wait_for_selector("#cfg-resultado >> text=PC-ESTOQUE04", timeout=20000)
    resultado = pagina.inner_text("#cfg-resultado")
    assert "✓ Recepção (PC-RECEPCAO01)" in resultado
    assert "✓ Financeiro (PC-FINANCEIRO02)" in resultado
    assert "✗ Vendas - Notebook (NB-VENDAS03): versão antiga" in resultado
    assert "✗ Estoque (PC-ESTOQUE04): offline" in resultado
    remotos = {e["host"] for e in painel.ENVIOS if e["path"] == "/api/settings"}
    assert {"PC-ADMIN01", "PC-RECEPCAO01", "PC-FINANCEIRO02"} <= remotos

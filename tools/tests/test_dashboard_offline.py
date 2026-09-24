"""
Teste do painel no navegador (Playwright), com a API simulada do
gerar_prints_readme.py: uma maquina da Frota offline precisa continuar
mostrando modelo/serie/SO e a foto do modelo da ultima leitura, mesmo depois
de recarregar a pagina.
"""
import json
import sys
from pathlib import Path

import pytest

playwright = pytest.importorskip("playwright.sync_api")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import gerar_prints_readme as painel  # noqa: E402

# Ultima leitura guardada da maquina "Estoque" (PC-ESTOQUE04, offline na API simulada).
SPECS_GUARDADAS = {"a4": {"manufacturer": "Dell Inc.", "model": "OptiPlex 3020", "serial": "EXEMPLO04",
                          "os_caption": "Microsoft Windows 11 Pro"}}


def test_maquina_offline_mantem_specs_e_foto_do_modelo():
    with playwright.sync_playwright() as p:
        try:
            browser = p.chromium.launch()
        except Exception as e:  # Chromium do Playwright nao instalado
            pytest.skip(f"Chromium indisponivel: {e}")
        ctx = browser.new_context()
        ctx.route("**/*", painel.responder)
        ctx.add_init_script(
            "localStorage.setItem('spooler_token', 'token-exemplo');"
            f"localStorage.setItem('spooler_fleet_specs_cache', {json.dumps(json.dumps(SPECS_GUARDADAS))});"
        )
        page = ctx.new_page()
        page.goto(painel.BASE + "/")
        page.evaluate("switchTab('frota')")
        page.wait_for_selector("#status-a4 >> text=Offline", timeout=15000)

        assert "OptiPlex 3020" in page.inner_text("#specs-a4")
        assert "EXEMPLO04" in page.inner_text("#specs-a4")

        foto = page.locator("#photo-a4")
        foto.wait_for(state="visible", timeout=10000)
        assert "/api/model-photo" in foto.get_attribute("src")

        # Maquina online sem nada guardado: specs chegam e passam a ficar guardadas.
        page.wait_for_function("() => document.querySelector('#specs-a1').innerText.includes('OptiPlex')")
        guardado = json.loads(page.evaluate("localStorage.getItem('spooler_fleet_specs_cache')"))
        assert guardado["a1"]["model"] == "OptiPlex 3020"
        browser.close()

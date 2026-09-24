"""Testes unitarios pra normalizacao de chave de modelo (sem rede/rembg)."""
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fetch_machine_photo import model_key  # noqa: E402


def test_strips_corporate_suffix():
    assert model_key("Dell Inc.", "OptiPlex 7050") == "Dell_OptiPlex_7050"


def test_matches_without_suffix():
    # Duas formas diferentes de escrever o mesmo fabricante devem virar a
    # mesma chave, pra biblioteca de fotos ser reaproveitada corretamente.
    assert model_key("Dell", "OptiPlex 7050") == model_key("Dell Inc.", "OptiPlex 7050")


def test_no_stray_punctuation_left_over():
    key = model_key("Dell Inc.", "OptiPlex 7050")
    assert ".." not in key
    assert not key.startswith("_")
    assert not key.endswith("_")


def test_manufacturer_without_suffix_unaffected():
    assert model_key("LENOVO", "IdeaPad Slim 3 15IRH10") == "LENOVO_IdeaPad_Slim_3_15IRH10"


# O monitor (PowerShell) calcula a mesma chave pra achar a foto do modelo na
# biblioteca. Se as duas implementacoes divergirem, a foto e salva com um
# nome e procurada com outro - e a maquina fica sem foto sem nenhum erro.
CASOS_CHAVE = [
    ("Dell Inc.", "OptiPlex 7050"),
    ("Dell", "Vostro 3401"),
    ("LENOVO", "IdeaPad Slim 3 15IRH10"),
    ("HP Inc.", "ProDesk 400 G6 SFF"),
    ("Acer", "Aspire A315-58"),
    ("ASUSTeK COMPUTER INC.", "VivoBook_ASUSLaptop X515EA"),
    ("Micro-Star International Co., Ltd.", "MS-7C95"),
    ("To Be Filled By O.E.M.", "To Be Filled By O.E.M."),
]


@pytest.mark.skipif(shutil.which("powershell") is None, reason="precisa do Windows PowerShell")
def test_powershell_model_key_matches_python():
    funcao = _funcao_do_monitor("Get-ModelPhotoKey")
    chamadas = "\n".join(
        f"Get-ModelPhotoKey -Manufacturer '{fab}' -Model '{mod}'" for fab, mod in CASOS_CHAVE
    )
    saida = subprocess.run(
        ["powershell", "-NoProfile", "-Command", funcao + "\n" + chamadas],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    assert saida == [model_key(fab, mod) for fab, mod in CASOS_CHAVE]


def _funcao_do_monitor(nome):
    monitor = (Path(__file__).resolve().parents[2] / "dist_spooler" / "app" / "SpoolerMonitor.ps1").read_text(encoding="utf-8-sig")
    return re.search(rf"^function {nome} \{{.*?^\}}", monitor, re.S | re.M).group(0)


@pytest.mark.skipif(shutil.which("powershell") is None, reason="precisa do Windows PowerShell")
def test_powershell_resolve_photo_path(tmp_path):
    # Monta um AppDir falso: biblioteca com a foto do modelo, uma maquina com
    # foto propria, e roda a funcao do monitor com Get-MachineSpecs simulado.
    (tmp_path / "photos-by-model").mkdir()
    (tmp_path / "photos-by-model" / "Dell_OptiPlex_7050.png").write_bytes(b"modelo")
    (tmp_path / "photos").mkdir()
    (tmp_path / "photos" / "PC-COM-FOTO.png").write_bytes(b"propria")

    script = "\n".join([
        _funcao_do_monitor("Get-ModelPhotoKey"),
        _funcao_do_monitor("Resolve-PhotoPath"),
        f"$AppDir = '{tmp_path}'",
        "function Get-MachineSpecs { [PSCustomObject]@{ manufacturer = 'Dell Inc.'; model = 'OptiPlex 7050' } }",
        "$env:COMPUTERNAME = 'PC-ESTA'",
        "Resolve-PhotoPath -FileName 'PC-ESTA.png'",      # sem foto propria -> modelo
        "$env:COMPUTERNAME = 'PC-COM-FOTO'",
        "Resolve-PhotoPath -FileName 'PC-COM-FOTO.png'",  # foto propria tem prioridade
        "$env:COMPUTERNAME = 'PC-ESTA'",
        "Resolve-PhotoPath -FileName 'OUTRA-MAQUINA.png'",  # outra maquina -> nao usa o modelo desta
    ])
    saida = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                           capture_output=True, text=True, check=True).stdout.splitlines()
    assert saida == [
        str(tmp_path / "photos-by-model" / "Dell_OptiPlex_7050.png"),
        str(tmp_path / "photos" / "PC-COM-FOTO.png"),
        str(tmp_path / "photos" / "OUTRA-MAQUINA.png"),
    ]

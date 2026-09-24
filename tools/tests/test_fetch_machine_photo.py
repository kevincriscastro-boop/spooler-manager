"""Testes unitarios pra normalizacao de chave de modelo (sem rede/rembg)."""
import sys
from pathlib import Path

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

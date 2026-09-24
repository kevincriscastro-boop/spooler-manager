#!/usr/bin/env python3
"""
Prepara a foto de um MODELO de equipamento para o Gerenciador do Spooler:
baixa uma foto de produto, remove o fundo (rembg) e salva recortada/
redimensionada na biblioteca:

  dist_spooler/app/photos-by-model/<Modelo>.png

Uma foto por modelo serve para todas as maquinas daquele modelo - o
monitor de cada maquina acha a sua pelo fabricante/modelo. 100 maquinas
de 5 modelos = 5 fotos. Se o modelo ja estiver na biblioteca, nao ha nada
a fazer.

Uso:
    python tools/fetch_machine_photo.py --manufacturer Dell --model "Vostro 3401" \\
        --image-url "https://.../foto-do-produto.jpg"

    # Excecao: foto propria de UMA maquina (ex: equipamento com visual
    # diferente do modelo). Fica em photos/<HOSTNAME>.png e tem prioridade
    # sobre a do modelo - ver PHOTOS_DIR.
    python tools/fetch_machine_photo.py --manufacturer Dell --model "Vostro 3401" \\
        --image-url "https://.../foto.jpg" --foto-propria PC-EXEMPLO01

O manufacturer/model normalmente vem do próprio /api/machine-info da
máquina (mesmos dados que já aparecem no painel). A URL da foto ainda
precisa ser encontrada manualmente (busca na web) - não há aqui nenhuma
integração automática de busca de imagens.
"""
import argparse
import re
import sys
import urllib.request
from io import BytesIO
from pathlib import Path

from PIL import Image
from rembg import remove

REPO_ROOT = Path(__file__).resolve().parent.parent
# Fotos proprias (por hostname) identificam maquinas reais, entao nao ficam
# neste repo: se houver um repositorio de dados ao lado
# (GerenciadorSpooler-Dados), salva la - o deploy junta essas fotos no
# pacote. Sem ele, salva na pasta do app (ignorada pelo Git).
DADOS_PHOTOS_DIR = REPO_ROOT.parent / "GerenciadorSpooler-Dados" / "photos"
PHOTOS_DIR = DADOS_PHOTOS_DIR if DADOS_PHOTOS_DIR.is_dir() else REPO_ROOT / "dist_spooler" / "app" / "photos"
LIBRARY_DIR = REPO_ROOT / "dist_spooler" / "app" / "photos-by-model"
MAX_WIDTH = 480
CROP_PADDING = 6


_SUFIXOS_CORPORATIVOS = re.compile(r"\b(Inc\.?|Corp\.?|Corporation|Ltd\.?|Co\.?|LLC)\b", re.IGNORECASE)


def model_key(manufacturer: str, model: str) -> str:
    """Nome de arquivo estavel pra biblioteca, ex: 'Dell_Vostro_3401'.

    O /api/machine-info de maquinas diferentes pode devolver o mesmo
    fabricante escrito de formas diferentes (ex: "Dell" vs "Dell Inc.") -
    remove sufixos corporativos comuns pra maximizar reaproveitamento.
    """
    manufacturer = _SUFIXOS_CORPORATIVOS.sub("", manufacturer).strip(" .")
    raw = f"{manufacturer}_{model}".strip("_")
    return re.sub(r"[^A-Za-z0-9._-]+", "_", raw).strip("_")


def crop_to_content(img: Image.Image, padding: int = CROP_PADDING) -> Image.Image:
    bbox = img.getbbox()
    if not bbox:
        return img
    left, top, right, bottom = bbox
    left = max(0, left - padding)
    top = max(0, top - padding)
    right = min(img.width, right + padding)
    bottom = min(img.height, bottom + padding)
    return img.crop((left, top, right, bottom))


def resize_max_width(img: Image.Image, max_width: int = MAX_WIDTH) -> Image.Image:
    if img.width <= max_width:
        return img
    new_height = int(img.height * (max_width / img.width))
    return img.resize((max_width, new_height), Image.Resampling.LANCZOS)


def process_and_save(source_bytes: bytes, dest_paths: list[Path]) -> None:
    print("Removendo fundo (rembg)...")
    no_bg = remove(source_bytes)
    img = Image.open(BytesIO(no_bg)).convert("RGBA")
    img = crop_to_content(img)
    img = resize_max_width(img)
    for dest in dest_paths:
        dest.parent.mkdir(parents=True, exist_ok=True)
        img.save(dest, format="PNG")
        print(f"Salvo: {dest} ({img.width}x{img.height}px)")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--manufacturer", required=True, help="Fabricante, como no painel. Ex: 'Dell Inc.'")
    parser.add_argument("--model", required=True, help="Modelo, como no painel. Ex: 'Vostro 3401'")
    parser.add_argument("--image-url", help="URL de uma foto de produto")
    parser.add_argument(
        "--foto-propria", metavar="HOSTNAME",
        help="Excecao: salva como foto propria desta maquina, em vez de foto do modelo",
    )
    args = parser.parse_args()

    key = model_key(args.manufacturer, args.model)
    if args.foto_propria:
        dest_path = PHOTOS_DIR / f"{args.foto_propria}.png"
    else:
        dest_path = LIBRARY_DIR / f"{key}.png"
        if dest_path.exists():
            print(f"Modelo '{key}' já está na biblioteca ({dest_path}) - nada a fazer.")
            print("Todas as máquinas desse modelo já exibem essa foto.")
            return

    if not args.image_url:
        print(f"Passe --image-url com uma foto de produto para '{key}'.", file=sys.stderr)
        sys.exit(1)

    print(f"Baixando {args.image_url} ...")
    req = urllib.request.Request(args.image_url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        source_bytes = resp.read()

    process_and_save(source_bytes, [dest_path])
    if not args.foto_propria:
        print("Faça commit da foto nova: ela passa a valer para todas as máquinas desse modelo.")


if __name__ == "__main__":
    main()

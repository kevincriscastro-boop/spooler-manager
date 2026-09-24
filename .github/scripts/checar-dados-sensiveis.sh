#!/usr/bin/env bash
# Barra dados do ambiente real no repositorio publico. Olha o conteudo do
# INDEX do Git (o que vai entrar no commit) - usado pelo hook de pre-commit
# (.githooks/pre-commit) e pelos workflows do GitHub.
#
#   1. Qualquer IPv4 fora da lista de permitidos (127.0.0.1, 0.0.0.0).
#   2. Termos proibidos (IP da VPS, hostnames, nome da empresa...) de um
#      arquivo de padroes, uma string por linha. A lista NAO fica neste repo -
#      publica-la ja vazaria os proprios nomes.
#
# So mostra ARQUIVO:LINHA, nunca o trecho encontrado - o log dos workflows e
# publico.
#
# Uso: checar-dados-sensiveis.sh [arquivo-de-padroes]

set -u
padroes="${1:-}"
falhou=0

ips=$(git grep --cached -nIoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' -- . ':!.github/scripts/checar-dados-sensiveis.sh' \
    | grep -vE ':(127\.0\.0\.1|0\.0\.0\.0)$' | cut -d: -f1,2 | sort -u)
if [ -n "$ips" ]; then
    echo "ERRO: endereco IP encontrado em:"
    echo "$ips" | sed 's/^/  /'
    falhou=1
fi

if [ -n "$padroes" ] && [ -s "$padroes" ]; then
    # Ignora linhas vazias e comentarios do arquivo de padroes.
    lista=$(mktemp)
    grep -vE '^\s*(#|$)' "$padroes" | tr -d '\r' > "$lista"
    termos=$(git grep --cached -nIiF -f "$lista" -- . | cut -d: -f1,2 | sort -u)
    rm -f "$lista"
    if [ -n "$termos" ]; then
        echo "ERRO: dado do ambiente real (termo da lista de padroes) encontrado em:"
        echo "$termos" | sed 's/^/  /'
        falhou=1
    fi
else
    echo "AVISO: sem lista de padroes - checando so enderecos IP."
fi

if [ "$falhou" -eq 1 ]; then
    echo
    echo "Troque por um valor ficticio (ex: PC-EXEMPLO01, seu-servidor) ou mova"
    echo "para o config.json / repositorio de dados, que ficam fora do Git."
    exit 1
fi
echo "OK - nenhum dado sensivel encontrado."

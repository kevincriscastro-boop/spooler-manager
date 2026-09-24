# Máquina parou de atualizar (config.json ausente)

Desde a versão `2026.09.24.4`, o endereço do servidor de atualização não fica mais
no código. Ele fica em `config.json`, que o deploy gera a partir do secret
`UPDATE_BASE_URL` e que o `Instalar.bat` copia para cada máquina.

Se esse arquivo não chegar numa máquina, **ela continua funcionando** (monitor,
limpeza da fila, painel), mas **para de receber atualizações**, sem nenhum aviso.

## Sintomas

- Na Frota, a máquina fica numa versão antiga enquanto as outras avançam.
- No painel dela, **Verificar Atualizações** mostra
  *"Não foi possível conectar ao servidor de atualização."*
- **Forçar Atualização**, no card da máquina na Frota, responde *"Servidor de
  atualização não configurado (config.json ausente)."*

## Diagnóstico (pelo AnyDesk, na máquina afetada)

No PowerShell:

```powershell
Get-Content C:\ProgramData\GerenciadorSpooler\config.json
```

| Resultado | Causa |
|---|---|
| Erro "não foi possível encontrar" | Arquivo ausente → siga a **Correção** |
| `update_base_url` vazio ou errado | Arquivo inválido → siga a **Correção** |
| URL certa | O problema é outro (rede, VPS fora do ar). Teste abrindo `<URL>/VERSION` no navegador da máquina |

## Correção

1. Pegue a URL certa do servidor. Ela está no `dist_spooler/app/config.json` do PC de
   desenvolvimento, que fica fora do Git. O secret do GitHub não mostra o valor
   depois de salvo.
2. Na máquina afetada, rode o PowerShell **como administrador** e troque a URL de
   exemplo pela real:

   ```powershell
   '{ "update_base_url": "http://SERVIDOR:PORTA" }' |
     Set-Content C:\ProgramData\GerenciadorSpooler\config.json -Encoding UTF8
   ```

3. Reinicie o monitor para ele ler o arquivo:

   ```powershell
   schtasks /end /tn GerenciadorSpoolerMonitor; schtasks /run /tn GerenciadorSpoolerMonitor
   ```

4. Confirme: no painel, **Verificar Atualizações** deve mostrar a versão do servidor.
   Se houver versão nova, use **Atualizar Agora** (ou **Forçar Atualização** no card
   da Frota), ou espere as janelas das 11h/15h.

## Se muitas máquinas pararam ao mesmo tempo

Nesse caso, provavelmente o problema está na publicação, não nas máquinas.

1. Rode os testes da VPS no PC de desenvolvimento:

   ```powershell
   python -m pytest tools/tests -m vps -v
   ```

   Se `test_published_zip_has_config_with_update_url` falhar, o zip publicado está
   sem `config.json`.

2. Confira em **GitHub > Settings > Secrets and variables > Actions** se
   `UPDATE_BASE_URL`, `VPS_HOST` e `VPS_PATH` existem, e rode o workflow
   **Publicar na VPS** de novo (aba Actions > *Run workflow*).
3. Se ainda assim não resolver, volte o código para a versão anterior:

   ```powershell
   git revert <commit>
   git push
   ```

   Suba o `VERSION` no mesmo commit, para as máquinas enxergarem a mudança. As
   máquinas que já estavam sem `config.json` precisam da **Correção** manual acima,
   porque sem o endereço elas não conseguem baixar nem a versão revertida.

## Por que isso não deveria acontecer

Três proteções evitam esse cenário:

- **Deploy (`.github/workflows/deploy.yml`):** para antes de publicar se o
  `config.json` não estiver dentro do zip.
- **`test_installer_copies_config_on_update`:** falha se alguém tirar o
  `config.json` da lista de arquivos que o `Instalar.bat` copia nas atualizações.
- **`test_published_zip_has_config_with_update_url`:** confere o zip que está de
  fato publicado na VPS.

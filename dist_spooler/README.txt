========================================================================
       GERENCIADOR DO SPOOLER DE IMPRESSÃO (Segundo Plano & Painel)
========================================================================

Este pacote gerencia o Spooler de Impressão do Windows, resolvendo 
automaticamente impressões travadas e fornecendo um painel visual para
administração e acompanhamento de métricas.

------------------------------------------------------------------------
1. COMO INSTALAR
------------------------------------------------------------------------
- Dê duplo clique no arquivo: Instalar.bat
- Na janela do Windows (UAC), clique em "Sim".
- O instalador configurará o serviço para iniciar com o Windows em segundo
  plano e criará os atalhos diretamente na sua Área de Trabalho.

------------------------------------------------------------------------
2. MONITORAMENTO EM SEGUNDO PLANO (> 5 MINUTOS)
------------------------------------------------------------------------
- O monitor roda silenciosamente no Windows a cada 30 segundos.
- Se qualquer impressão permanecer retida na fila por mais de 5 minutos:
    * O Spooler será reiniciado e a fila será limpa automaticamente.
    * Uma janela demonstrando os 5 passos será exibida na tela.
    * Uma notificação surgirá no canto inferior direito do Windows.
    * O evento será registrado no histórico e o contador "Automático" 
      será incrementado.

------------------------------------------------------------------------
3. PAINEL DE ADMINISTRAÇÃO
------------------------------------------------------------------------
- Abra pelo atalho "Painel Admin - Spooler" na Área de Trabalho ou 
  clique em "Painel_Admin.bat" nesta pasta.
- Credenciais iniciais:
    * Usuário: admin
    * Senha:   admin
- Recursos do Painel:
    * Total de reinícios automáticos (fila presa > 5 min).
    * Total de execuções forçadas (manuais).
    * Total de impressões limpas.
    * Status da fila e do serviço em tempo real.
    * Histórico completo de eventos.
    * Botão "Forçar Reinício e Limpeza Agora".
    * Opção "Trocar Senha" para alterar a senha do usuário admin.

------------------------------------------------------------------------
4. FROTA DE MÁQUINAS (gerenciar várias máquinas de um lugar só)
------------------------------------------------------------------------
- Instale este mesmo pacote em CADA máquina que você quer monitorar
  (produção) e também na máquina de onde você quer acompanhar tudo
  (ex: seu computador do escritório).
- No painel de QUALQUER máquina, clique na aba "🌐 Frota de Máquinas".
- Cadastre cada máquina pelo NOME DO COMPUTADOR (ex: PRODUCAO-01) - não
  precisa saber o IP, e continua funcionando mesmo se o IP mudar.
  Para descobrir o nome de uma máquina: Win+Pause, ou "hostname" no CMD.
- Você verá o status de cada uma em tempo real (Spooler ativo/parado,
  impressora(s) instalada(s), fila atual) e pode clicar em
  "⚡ Forçar Reinício" para resolver remotamente, sem sair do lugar.
- Clique em "Abrir Painel" num card pra ver o histórico detalhado
  daquela máquina específica (qual impressora precisou de reinício etc).

IMPORTANTE - SEGURANÇA:
- A Frota exige que todas as máquinas usem A MESMA senha de admin.
- Como isso abre a porta 8989 para a rede local (antes só funcionava
  no próprio PC), é ALTAMENTE recomendado trocar a senha padrão
  "admin/admin" em TODAS as máquinas assim que instalar (opção
  "Trocar Senha" no painel). Sem isso, qualquer pessoa na mesma rede
  poderia acessar o painel.
- Só libere isso em redes internas confiáveis (LAN da empresa), nunca
  exponha a porta 8989 diretamente para a internet.

------------------------------------------------------------------------
5. DESINSTALAÇÃO OU REINSTALAÇÃO
------------------------------------------------------------------------
- Para desinstalar completamente: Execute Desinstalar.bat
- Para reiniciar/reconfigurar do zero: Execute Reinstalar.bat
========================================================================

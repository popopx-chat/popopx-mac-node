import Foundation

/// Full console catalogs for the three languages added on 2026-11-27.
///
/// Each catalog is a TSV blob (`key<TAB>text`, one row per key, in the same
/// order as the `I18N` table in `LocalWebConsoleServer.swift`). They live here
/// rather than as extra fields on every `I18N` row so the Traditional Chinese
/// derivation keeps reading exactly `{ zh, en }` rows, and they are injected
/// into the page as side tables (`PTBR`, `KO`, `AR`).
///
/// The parser drops a malformed line instead of guessing;
/// `ConsoleLocalizationTests` pins each catalog's key set to the English base
/// table, so a dropped row fails a test rather than silently painting the
/// English fallback.
enum ConsoleTranslations {
    typealias Row = (key: String, text: String)

    static let portugueseRows = rows(from: portuguese)
    static let koreanRows = rows(from: korean)
    static let arabicRows = rows(from: arabic)

    static func rows(from blob: String) -> [Row] {
        blob.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let key = String(line[..<tab])
            let text = String(line[tab...].dropFirst())
            guard !key.isEmpty, !text.isEmpty else { return nil }
            return (key, text)
        }
    }

    /// One JavaScript object literal. Keys and values go through the same
    /// escaper the rest of the console uses, so a quote or U+2028 in a
    /// translation cannot take the inline script down.
    static func javascript(_ rows: [Row]) -> String {
        "{" + rows.map { "\(WEBConsoleHTML.jsLiteral($0.key)):\"\(WEBConsoleHTML.jsLiteral($0.text))\"" }
            .joined(separator: ",") + "}"
    }

    /// Português (Brasil) — translated in full 2026-11-27.
    private static let portuguese = #"""
brandSub	Hub de computação local e execução física · somente loopback
brandClaim	Connect Everything. Conecte tudo e deixe a inteligência colaborar livremente.
brandSlogan	Conecte-se livremente · Comunique-se em privado · Colabore com inteligência
brandPosition	Plataforma de Conexão Inteligente com Privacidade em Primeiro Lugar
brandRole	O nó de computação de borda no dispositivo e de execução de privacidade do POPOPX, a Plataforma de Conexão Inteligente com Privacidade em Primeiro Lugar
brandMission	O POPOPX não se limita a oferecer ferramentas de conexão — ele constrói um ecossistema aberto onde pessoas, IA, agentes, dispositivos e serviços se conectam com segurança e colaboram livremente.
loadingShort	Carregando
connecting	Conectando
live	Conectado
retryState	Reconectando
offline	Desconectado
offlineBanner	O canal ao vivo com o nó caiu. Esta página mostra o último snapshot lido com sucesso.
retry	Reconectar agora
langGroup	Idioma do console
langFallback	Ainda não há catálogo revisado, então a página permanece em inglês (os resumos e scripts continuam usando o idioma escolhido)
langSaveHint	A página mudou; o nó mantém o próprio idioma até você pressionar Salvar
langSaveFailed	Não foi possível guardar a configuração de idioma; voltando ao idioma que o nó usa
railAria	Etapas de configuração
s1	Hardware e implantação
s2	Emparelhamento do iPhone
s3	Motores e autoridade física
s1Title	Etapa 1 · Varredura de hardware e instalação com um clique
s1Desc	Lê o perfil do Apple Silicon, escolhe a pilha de modelos a partir da memória unificada e instala os motores de IA locais neste Mac.
s2Title	Etapa 2 · Emparelhe o iPhone
s3Title	Etapa 3 · Dez motores e autoridade física
s3Desc	Chaves, compartilhamento de computação ociosa, a sentinela física e a arca cronológica. Toda alteração é gravada explicitamente em config/settings.json.
loading	Aguardando o primeiro snapshot…
loadFailed	Não foi possível ler o estado do nó
reloadRetry	Tentar novamente
noData	Ainda sem dados
chip	Chip
cores	Núcleos de CPU
coresNote	desempenho P · eficiência E
mem	Memória unificada
memNote	Pool compartilhado do Apple Silicon
freeDisk	SSD livre
freeDiskNote	do total
tier	Nível de computação
loadTitle	Carga ao vivo
loadNote	amostrado
memUsed	Memória em uso
pressure	Pressão de memória
processes	Processos
cpu	Carga de CPU
nominal	Normal
warning	Alerta
critical	Crítico
memTitle	Medidor de memória unificada
usedOf	em uso de
toolchainTitle	Sondagens de toolchain
toolchainEmpty	O nó ainda não informou nenhuma sondagem de toolchain.
present	presente
missing	ausente
stepsTitle	Lista de provisionamento
stepsEmpty	Nenhuma implantação executada ainda. Pressione a implantação com um clique para começar.
logTitle	Log de instalação ao vivo
levelFilter	Filtro de nível do log
filterAll	Todos os níveis
filterInfo	info e acima
filterNotice	aviso e acima
filterWarning	alerta e acima
filterError	somente erro
copyLog	Copiar log
clearLog	Limpar
logCleared	Visualização limpa (o log do lado do nó foi mantido)
logLines	linhas de log
logLocked	Rolagem automática pausada
logUnlock	Retomar a rolagem automática
logEmpty	A janela de log está vazia. Ela começa a transmitir assim que uma implantação é executada.
logCopied	Log copiado
deploy	Implantar motores de IA locais com um clique
cancelInstall	Cancelar implantação
idleHint	Sonda brew / ffmpeg / uv / Ollama, baixa os pesos que cabem no nível de memória e prepara o workspace do LTX-2.5.
installing	Implantação em andamento
phaseIdle	Ocioso
phaseDetecting	Detectando
phaseProvisioning	Provisionando
phasePullingLLM	Baixando LLM
phasePreparingWorkspace	Preparando workspace
phaseDownloadingWeights	Baixando pesos
phaseVerifying	Verificando
phaseReady	Motores prontos
phaseFailed	A implantação falhou
phaseCancelled	Cancelado
deployStarted	Implantação solicitada
deployFailed	Não foi possível iniciar a implantação
deployCancel	Cancelamento solicitado
deployCancelFailed	Falha no cancelamento
installDone	Os motores locais estão prontos
installFailedWhy	A última implantação falhou
planTitle	Escada de modelos recomendada
planNote	Justificativa do plano
thBand	Faixa de memória
thLLM	Modelo de linguagem
thVideo	Precisão de vídeo
thResident	Residente
thNote	Política
tierCap	Local em precisão total
tierQuant	Local quantizado
tierLight	Local leve
heavyLocal	Vídeo pesado renderiza localmente
heavyMesh	Vídeo pesado encaminhado para a malha
noPlan	O nó ainda não gerou um plano de modelos.
modelTitle	Gerenciamento de modelos
modelDefault	Padrão · por nível de memória
modelResident	Estimativa residente
modelAdmission	Admissão de memória
modelGguf	GGUF personalizado
modelCopyPull	Copiar comando de download
modelSwapWarn	Este Mac está na linha de swap ou abaixo dela: trabalhos locais pesados são recusados em vez de arriscar um travamento por OOM.
modelSwitched	Modelo local alterado
modelSwitchFailed	Não foi possível alterar o modelo local
modelUnpinned	De volta ao nível do hardware
modelPinnedNote	Fixado — não segue mais o nível de memória
modelUnknown	Este modelo não está no catálogo, então os números de memória continuam sendo a estimativa do próprio nível.
modelCardTitle	Modelo local e modo leve
modelMode	Modo
modelModeLite	Leve · zero modelos
modelModeEnhanced	Com IA · pronto
modelModeNoModel	Com IA · download pendente
modelPullBtn	Baixar agora
modelPulling	Baixando…
modelCancelBtn	Cancelar download
modelLiteOn	Mudar para o modo leve
modelLiteOff	Sair do modo leve
modelProgress	Progresso do download
modelReadyLabel	Modelo local pronto
modelFailed	O download não foi concluído
modelNone	Não há modelo para baixar
modelPullStarted	Download iniciado
modelPullFailed	A solicitação de download falhou
modelBoundary	Os downloads passam apenas pelo Ollama local em 127.0.0.1; nenhum peso entra no instalador nem sai deste Mac.
modelFeatureOff	desligado no modo leve
asMailPreset	Predefinição de provedor de e-mail
asMailPresetNone	Preencher manualmente
asMailPresetHint	Escolher um provedor preenche os hosts e as portas IMAPS/SMTPS; use uma senha específica de app e guarde-a no Keychain ao lado.
asMailPresetApplied	Modelo aplicado
qrTitle	QR de emparelhamento
qrSub	Escaneie no iOS · Descobrir → Emparelhamento com o Mac Node. O túnel criptografado sobe na mesma rede.
qr	Código QR
qrRetry	Recarregar o QR
qrLoading	Gerando o QR…
qrLoadFailed	Não foi possível carregar a imagem do QR
noQR	O nó não consegue gerar a imagem do QR agora; o link criptografado abaixo continua válido e pode ser colado manualmente no iOS.
code	Código de emparelhamento com criptografia ponta a ponta
copyCode	Copiar código
uri	URI de convite /*PPX_SCHEME*/
copyURI	Copiar URI
pairLink	Link de emparelhamento criptografado
copyLink	Copiar link
pairLinkNote	O link é selado com o formato de convite do ecossistema, então não nomeia nenhum nó de sinalização; o QR contém exatamente os mesmos bytes.
pairDiagTitle	Credenciais de emparelhamento brutas (somente neste Mac)
pairDiagNote	O código e a URI de convite abaixo carregam o endereço da fila SMP e servem para diagnóstico; compartilhe o link criptografado acima.
pairDiagEmpty	Ainda sem credencial de emparelhamento; regenere uma oferta e os valores brutos aparecem aqui.
pubkey	Chave pública do nó
expiry	Válido por
expired	Este código de emparelhamento expirou
used	Este código de emparelhamento já foi usado
oneTime	uso único
rotate	Regenerar
rotateFailed	Não foi possível regenerar a oferta de emparelhamento
noPairing	O gateway de sinalização ainda não emitiu uma oferta. Ela aparece quando o daemon estiver ativo.
tunnel	O túnel criptografado com o iPhone está ativo
tunnelSub	A chave deste dispositivo está na lista de permitidos; só ela pode operar os dez motores neste Mac.
devices	Dispositivos emparelhados
devicesEmpty	Nenhum dispositivo concluiu o handshake do QR ainda.
revoke	Revogar
revokeDone	Dispositivo revogado
revokeFailed	Falha ao revogar
revokedRow	revogado
deviceModel	Modelo
pairedAt	Emparelhado em
lastSeen	Visto por último
neverSeen	nunca visto
copyPubkey	Copiar chave
bridgeTitle	Ponte de sinalização SMP
daemonStopped	Daemon parado
daemonStarting	Daemon iniciando
daemonRunning	Daemon em execução
daemonDegraded	Daemon degradado
daemonMissing	Binário popopx-chat ausente
accepted	Aceitos
rejected	Rejeitados
delivered	Entregues
outbox	Profundidade da caixa de saída
uptime	Tempo ativo
wsOn	WebSocket ativo
wsOff	WebSocket inativo
daemonPath	Caminho do daemon
bridgeErr	Último erro
daemonInstall	O popopx-chat não está instalado —— baixe, verifique e então execute: curl -o- https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh > popopx-install.sh; shasum -a 256 popopx-install.sh (o digest deve ser igual ao da seção de instalação do README — se não for, não execute o script); bash popopx-install.sh instala o executável como ~/.local/bin/popopx-chat
enginesTitle	Dez motores de negócio
enginesBadge	ativos
enginesLoading	Aguardando os descritores dos motores…
runs	execuções
failures	falhas
artifacts	artefatos
lastRun	última
busyNow	ocupado
idleNow	ocioso
requires	requer
needsModels	requer modelos locais
deterministicFlag	determinístico · sem modelo
toggleOn	Ativado
toggleOff	Desativado
toggleFailed	Falha na solicitação de alteração
save	Salvar configurações
saving	Salvando…
saved	As configurações coincidem com o nó
dirty	Edições locais não salvas
saveDone	Configurações gravadas
saveFailed	Falha ao salvar
conflict	O nó tem uma revisão mais nova; o formulário foi recarregado a partir dela
revision	revisão
revert	Descartar
reverted	Revertido para o documento do nó
meshTitle	Compartilhamento de computação ociosa
meshOn	compartilhamento ativo
meshOff	compartilhamento desligado
shareEnable	Emprestar ciclos ociosos
maxMem	Memória máxima
maxMemHint	teto seguro nesta máquina
maxJobs	Trabalhos simultâneos
minFree	GB mínimos livres em disco
ownerPresent	Somente enquanto o proprietário estiver presente
windows	Janelas ociosas
windowAdd	Adicionar janela
windowRemove	Remover
windowEmpty	Sem nenhuma janela, o nó nunca aceita trabalho.
from	De
to	Até
weekdayShort	Dias
acceptingNow	Aceitando agora
notAcceptingNow	Não aceita agora
accrued	Pontos acumulados
settled	Trabalhos liquidados
activeJobs	Trabalhos ativos
nextWindow	Próxima janela
meshSandbox	Bytes de sandbox
sentinelTitle	Sentinela do espaço físico
sentinelSub	Bloqueio determinístico: nenhum modelo no circuito, dispara com 🔒 / LOCK_ALL na hora.
sentinelOn	Sentinela armada
sentinelOff	Sentinela desligada
mounts	Volumes para desmontar
mountAdd	Adicionar caminho
mountEmpty	Nenhum caminho de montagem configurado; o bloqueio apenas limpará a área de transferência, bloqueará a tela e chamará o webhook.
mountHint	ex.: /Volumes/ENCRYPTED ou smb://… (desmontado via diskutil no momento do bloqueio)
clipboard	Limpar a área de transferência ao bloquear
lockScreen	Bloquear a tela
sleepDisplays	Suspender os monitores
phrases	Frases de disparo (separadas por vírgula)
hookUrl	URL do Home Assistant / webhook
hookSecret	Segredo de assinatura do webhook
secretShow	Mostrar
secretHide	Ocultar
drill	Executar simulação agora
drillDone	Recibo da simulação retornado
drillFailed	A simulação falhou
drillPending	Simulação em andamento…
drillTitle	Recibos de bloqueio determinístico
receiptEmpty	Nenhum bloqueio registrado ainda. Pressione executar simulação agora para gerar um.
modelFree	sem modelo
modelUsed	modelo envolvido (inesperado)
receiptTrigger	Gatilho
receiptClip	Área de transferência
receiptUnmount	Desmontados
receiptMountFail	Falhas ao desmontar
receiptScreen	Tela
receiptWebhook	Webhook
receiptElapsed	Tempo decorrido
arkTitle	Chrono Ark
arkSub	Bloqueio temporal criptográfico e guarda por batidas perdidas; abre no prazo ou após silêncio.
arkOk	Guardião saudável
arkAlert	Batida atrasada
beat	Intervalo de batida (horas)
missed	Batidas perdidas toleradas
graceDue	Prazo de liberação
lockDur	Bloqueio temporal (segundos)
lockDays	cerca de
daysUnit	dias
unlocks	desbloqueio mais cedo
directory	Diretório do arquivo criptografado
dirHint	Fixo, definido pelo nó em vault/sealed/, que é exatamente onde o chrono_ark grava as cápsulas
dirReveal	Revelar no Finder
dirUnsupported	Uma página não pode listar diretórios locais nem alterar este caminho; “Revelar no Finder” é executado pelo nó nesta máquina.
revealFailed	O nó não conseguiu abrir a pasta do arquivo
archives	Arquivos selados
archivesEmpty	Nada foi selado ainda.
archiveSealedAt	selado em
archiveOpens	abre
archiveRounds	rodadas
archiveFingerprint	impressão digital da chave
archiveOpen	após o bloqueio
archiveSealed	ainda selado
beneficiary	Nome do beneficiário
beneficiaryQueue	Fila de beneficiários
devTitle	Painel do desenvolvedor
devHint	JSON bruto do snapshot e injeção de comandos de rede
devOpen	Expandir
devClose	Recolher
rawFetch	Buscar snapshot bruto
rawCopy	Copiar JSON
rawEmpty	Ainda não buscado.
rawFailed	Falha na busca
rawTruncated	Truncado para exibição
cmdLabel	Injetar um comando ::popopx_sys::NODE_CMD
cmdHint	Formato ::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}; ele percorre exatamente o mesmo caminho de um comando do iOS.
cmdSend	Executar
cmdClear	Limpar saída
cmdEmpty	Digite um comando primeiro
cmdDone	Comando executado
cmdFailed	Falha no comando
copyDone	Copiado para a área de transferência
copyFailed	Falha ao copiar
loopbackNote	A página e a API vêm somente de 127.0.0.1; nenhum script, fonte ou rastreador externo.
unknown	desconhecido
yes	sim
no	não
never	nunca
secondsUnit	s
ago	atrás
paired	Emparelhado
released	Liberado
now	agora
s4	Pontes de privacidade
s4Title	Pontes de privacidade e confirmação manual
s4Desc	Dados brutos de calendário e de workspace são lidos somente neste Mac; o que aparece aqui é o resumo do próprio nó e as ações que aguardam você.
pvGuarantee	Tudo nesta página vem do snapshot de loopback: títulos de eventos, locais, participantes e corpos de arquivos são descartados antes da codificação, e toda escrita exige uma segunda confirmação aqui ou em um iPhone emparelhado.
pvAccessTitle	Chaves de autorização
pvAuthNote	Uma chave é a própria concessão do nó; o macOS ainda pode negar o acesso ao calendário separadamente, então o estado do sistema aparece abaixo.
pvCalSwitch	Ler horários livres/ocupados do calendário (não o conteúdo dos eventos)
pvReadSwitch	Resumir arquivos dentro dos diretórios autorizados
pvWriteSwitch	Escrever dentro dos diretórios autorizados (cada escrita confirmada)
pvNotifySwitch	Notificar na Central de Notificações quando chegar uma proposta
pvAskAccess	Pedir acesso ao calendário ao macOS
pvAuthAgain	Perguntar ao macOS de novo
pvAuthAsked	Estado de autorização atualizado pelo macOS
pvAuthAskFailed	A solicitação de acesso falhou
pvCheck	Verificar os próximos 7 dias
pvCheckOff	A ponte de calendário está desligada, então nenhuma consulta é enviada
pvCheckFree	Horários livres encontrados
pvCheckNone	Nenhum horário livre nesta janela
pvCheckFailed	Verificação recusada
pvDirsTitle	Diretórios autorizados
pvDirAdd	Adicionar diretório
pvDirRemove	Remover
pvDirHint	Escreva no estilo do usuário, por exemplo ~/Documents/Projects. O nó guarda os três primeiros e só lê dentro deles.
pvDirEmpty	Nenhum diretório ainda; resumos e escritas são ambos recusados.
pvDirMax	Limite de diretórios atingido, remova um primeiro
pvDirOpen	Presente e acessível
pvDirClosed	Ausente ou inacessível
pvDirsKnown	Diretórios que o nó realmente aceita e resolve
pvDirsKnownNote	Esta coluna é a resposta do nó, não as caixas de entrada: ela só coincide depois de salvar, e uma entrada descartada significa que o limite foi ultrapassado.
pvDirNoneSaved	O nó não aceitou nenhum diretório
pvRulesTitle	Regras de horários livres e padrões das propostas
pvWorkStart	Início do expediente
pvWorkEnd	Fim do expediente
pvDuration	Duração padrão (min)
pvBuffer	Margem ao redor (min)
pvLunchStart	Início do almoço
pvLunchEnd	Fim do almoço
pvBlockLunch	Tratar o almoço como ocupado
pvWorkdays	Dias úteis
pvZone	Fuso horário
pvZoneNote	Vazio significa o fuso atual do Mac.
pvCallTemplate	Modelo de link da chamada
pvCallNote	{ref} e {node} são substituídos; vazio significa que as propostas não levam link.
pvPropTitle	Propostas aguardando você
pvBookTitle	Reservas criadas por este nó
pvAuditTitle	Trilha de auditoria local
pvAuditCopy	Copiar trilha
pvNone	Nada aguardando uma decisão
pvNoBookings	Este nó ainda não gravou nenhum evento de calendário
pvNoAudit	Nenhum registro ainda
pvStatPending	Aguardando
pvStatBookings	Reservas
pvStatDirs	Dirs. acessíveis
pvStatDirsNote	acessíveis / limite
pvBadgePending	Aguardando você
pvBadgeQuiet	Nada para você
pvActCreate	criar evento
pvActReschedule	reagendar
pvActCancel	cancelar evento
pvActWrite	gravar arquivo
pvActOrganize	organizar arquivos
pvActInvoke	chamar ferramenta
pvStatePending	aguardando você
pvStateApproved	aprovada
pvStateExecuted	executada
pvStateRejected	rejeitada
pvStateExpired	expirada
pvStateFailed	falha na execução
pvStateCancelled	anulada
pvDomainCal	calendário
pvDomainWs	workspace
pvDomainMCP	MCP
pvDomainHome	casa
pvApprove	Aprovar e executar
pvReject	Rejeitar
pvConfirmAgain	Clique de novo para confirmar
pvCannotApprove	Esta não pode ser executada: a chave ou o diretório de que ela precisa está desligado
pvTtlOver	tempo esgotado
decisionDone	Sua decisão foi aplicada
decisionFailed	Não foi possível aplicar a decisão
s5	Pontes do hub de borda
s5Title	Descoberta local e pontes de protocolo
s5Desc	Somente este Mac e os endereços privados que você listar são sondados. Toda capacidade começa desligada, e uma capacidade ativada ainda passa pela mesma confirmação dupla.
hvGuarantee	Tudo aqui é servido a partir do endereço de loopback: nenhuma saída, nenhuma varredura de portas, nenhum host adivinhado. Um alvo público é recusado antes de existir um socket, e a contagem e o motivo são listados.
hvDiscTitle	Descoberta de capacidades locais
hvDiscIdle	Nada medido ainda
hvScan	Sondar agora
hvScanning	medindo
hvScanFailed	A sondagem falhou
hvBoundary	Loopback mais os alvos de LAN que este proprietário listou
hvKindEngine	motor
hvKindModel	modelo
hvKindWorkspace	workspace
hvKindCalendar	calendário
hvKindLan	LAN
hvKindRefused	recusado
hvStatePresent	presente
hvStateAbsent	ausente
hvStateInstalled	instalado
hvStateAuthorized	autorizado
hvStateDenied	negado pelo macOS
hvStateOff	desligado
hvStateReachable	acessível
hvStateSilent	silencioso
hvStateRefused	recusado
hvStateFull	autorizado
hvStateWrite	somente escrita
hvStateRestricted	restrito
hvStateNotAsked	ainda não solicitado
hvStateNoBridge	não conectado
hvStatCaps	Capacidades
hvStatRefused	Alvos recusados
hvStatRefusedNote	nenhuma conexão tentada
hvStatServers	Servidores MCP
hvStatServersNote	registrados / conectados
hvStatEntities	Entidades visíveis
hvStatEntitiesNote	da lista de permitidos
hvBadgePending	Aguardando você
hvBadgeOn	Pontes ativas
hvBadgeOff	Tudo desligado
hvPropTitle	Ações de ponte aguardando você
hvPropNone	Nenhuma ação de ponte aguarda uma decisão
hvSwitchTitle	Chaves de ponte (todas desligadas por padrão)
hvSwitchNote	Uma chave só passa a valer quando há algo por trás dela: sem servidor MCP registrado, sem endereço do Home Assistant ou do broker e sem servidor CalDAV, o nó a considera desligada.
hvMcpSwitch	Ativar o cliente MCP local (stdio ou HTTP em loopback)
hvHomeSwitch	Ativar Home Assistant e MQTT (somente rede privada)
hvCalDavSwitch	Ativar CalDAV livre/ocupado (somente janelas, nunca o conteúdo dos eventos)
hvAutoScan	Sondar as capacidades locais ao abrir o console
hvReadonly	Casa inteligente somente leitura: espelhar o estado, nunca acionar
hvTelemetry	Aceitar telemetria MQTT (requer filtros de tópico)
hvStatusTitle	Status das pontes
hvStatusIdle	ainda não consultado
hvChecking	consultando
hvRefresh	Consultar de novo
hvGateNote	As três linhas vêm dos mesmos pontos de entrada de ferramentas que um iPhone emparelhado usa: chamadas somente leitura são executadas, qualquer coisa que altere o estado vira proposta e é gravada no log de auditoria local.
hvBridgeMCP	Cliente MCP
hvBridgeHome	Home Assistant · MQTT
hvBridgeCalDav	CalDAV livre/ocupado
hvHaOk	Home Assistant configurado
hvHaAbsent	Home Assistant ausente
hvMqttOk	broker conectado
hvMqttAbsent	broker não conectado
hvRejectedEntries	entradas de registro recusadas
hvHaUrl	URL do Home Assistant
hvHaNote	Somente loopback, 10/8, 172.16/12, 192.168/16 e .local; um endereço público ou domínio externo é recusado antes de existir um socket.
hvHaToken	Token de acesso de longa duração (Keychain)
hvMqttHost	Host MQTT
hvMqttHostPlaceholder	por exemplo 192.168.1.20
hvMqttNote	A mesma fronteira de rede privada; o nó fala MQTT v3.1.1 por conta própria, sem terceiros no meio.
hvMqttPassword	Senha MQTT (Keychain)
hvSecretSave	Guardar no Keychain
hvSecretStored	A credencial está guardada de forma criptografada
hvMqttPort	Porta MQTT
hvSecretFailed	A credencial não foi guardada
hvSecretEmpty	Informe a credencial primeiro
hvServerRequired	Informe o servidor CalDAV primeiro
hvCalDavId	Id do servidor CalDAV
hvCalDavIdNote	Deve corresponder a um servidor já listado no documento de configurações.
hvCalDavPassword	Senha do CalDAV ou token de app
hvCalDavPasswordNote	Apenas referência, de novo: o nó nunca coloca o valor no arquivo de configurações, em uma linha de log ou em qualquer resposta que esta página leia.
hvEntitiesTitle	Lista de entidades permitidas
hvEntityAdd	Adicionar entidade
hvEntityNote	Uma entidade que não está listada aqui não existe para este nó. Fechaduras, alarmes, sirenes, câmeras e aspiradores precisam da segunda confirmação mesmo quando estão listados.
hvEntityEmpty	A lista de permitidos está vazia, então a ponte é considerada desligada
hvEntityLimit	A lista de permitidos atingiu o limite
hvTargetsTitle	Alvos de sondagem na LAN (opcional)
hvTargetAdd	Adicionar alvo
hvTargetNote	Host e porta. Uma tentativa TCP com timeout de 350 ms; um endereço público é recusado e contado em alvos recusados acima.
hvTargetEmpty	Nenhum alvo listado, então somente este Mac é sondado
hvTargetLimit	A lista de sondagem atingiu o limite
upTitle	Atualizações assinadas
upDesc	Um único manifesto HTTPS fixado pelo proprietário é a única busca; uma assinatura inválida ou uma versão que não seja mais nova é ignorada sem exibir cartão.
upCheck	Verificar atualizações
upChecking	verificando
upCheckFailed	A verificação falhou
upFound	Uma nova versão está disponível
upUpToDate	Já está atualizado
upIgnored	ignorado em silêncio
upFailed	A ação de atualização falhou
upDone	concluído
upBadgeReady	Aguardando você
upBadgeOn	Atualizações ativas
upBadgeIncomplete	Incompleto
upBadgeOff	Atualizações desligadas
upCurrent	Versão atual
upKey	Chave do manifesto
upLastCheck	Última verificação
upInstalled	instalado
upPendingTitle	pronto para instalar
upNoPending	Nenhuma versão aguarda uma decisão
upBuild	build
upReleased	lançado
upPackage	pacote
upSummary	O que há de novo
upApprove	Atualizar agora
upSnooze	Lembrar mais tarde
upConfirmAgain	Clique de novo para confirmar
upRefused	recusado
upConfigTitle	Feed de atualizações (configurado pelo proprietário)
upSwitchNote	Você fornece o manifesto e a chave; o nó nunca busca uma chave no host do manifesto e nunca segue um redirecionamento.
upEnabled	Ativar verificações de atualização assinadas
upManifestURL	URL do manifesto
upManifestNote	Deve ser https na porta 443 com exatamente o host que você digitou; todo redirecionamento é recusado.
upPublicKey	Chave pública Ed25519 (base64url)
upKeyNote	Uma chave de 32 bytes; a impressão digital dela aparece nas estatísticas acima e a verificação usa apenas esse valor.
upPackageHosts	Hosts de pacote permitidos (separados por vírgula)
upPackageNote	O host do manifesto é sempre permitido; liste apenas hosts extras que um manifesto assinado possa indicar, como um CDN.
upInterval	Intervalo de verificação (minutos)
upSnoozeHours	Duração da soneca (horas)
upGateNote	A detecção é automática, a instalação não: nada é baixado antes de você pressionar Atualizar agora, e um pacote baixado é conferido quanto ao tamanho em bytes e ao SHA-256 antes de o macOS abri-lo.
dcFeedTitle	Itens mais recentes
dcEmpty	Nenhum item ainda; pressione atualizar
dcRefresh	Atualizar agora
dcRefreshing	atualizando
dcRefreshFailed	A atualização falhou
dcRefreshNote	O cartão carrega um índice legível; o conteúdo assinado é o feed.json, entregue na mesma sessão criptografada e gravado no log de auditoria local.
dcConfigTitle	Configurações do agregador
dcSwitchNote	Desligado por padrão; mesmo ativado, ele é considerado desligado até existir uma pasta, feed ou fonte MCP.
dcEnabled	Ativar o agregador Discover
dcBadgeOn	Agregador ativo
dcBadgeOff	Agregador desligado
dcInterval	Intervalo de atualização (minutos)
dcMaxItems	Máximo de itens por execução
dcFoldersTitle	Pastas locais (somente texto)
dcFolderAdd	Adicionar pasta
dcFolderNote	Somente arquivos de texto simples dentro da sua pasta pessoal são lidos; links simbólicos, arquivos grandes demais e pastas aninhadas profundamente demais são ignorados.
dcFolderEmpty	Nenhuma pasta adicionada
dcFolderLimit	A lista de pastas atingiu o limite
dcFeedsTitle	Feeds RSS / JSON (somente rede privada)
dcFeedAdd	Adicionar feed
dcFeedOn	ativo
dcFeedNote	Um endereço público é recusado pelo EdgeBoundary antes de existir um socket e aparece no status das fontes abaixo.
dcFeedEmpty	Nenhum feed adicionado
dcFeedLimit	A lista de feeds atingiu o limite
dcMcpTitle	Fontes MCP somente leitura
dcMcpAdd	Adicionar fonte MCP
dcMcpNote	Somente ferramentas de leitura; uma ferramenta que altera o estado nunca é executada pelo agregador.
dcMcpEmpty	Nenhuma fonte MCP adicionada
dcMcpLimit	A lista MCP atingiu o limite
dcSourcesTitle	Status das fontes
dcSourcesIdle	ainda não executado
dcSourcesNote	Cada execução é gravada no log de auditoria local; a entrega ainda usa a sessão ponta a ponta vinculada.
dcStatItems	Itens
dcStatSources	Fontes
dcStatLastRun	Última execução
dcStatDelivered	Última entrega
dcKindFolder	pasta
dcKindRSS	RSS / Atom
dcKindJSON	Feed JSON
dcKindMCP	MCP
dcStateOk	ok
dcStateRefused	recusado
geTitle	Mapa de inteligência global (God's Eye View)
geDesc	Um programa de terceiros separado que você instala e executa neste Mac; este nó apenas verifica uma versão fixada, o inicia em 127.0.0.1 e registra a entrada MCP verificada como ferramenta de leitura prioritária.
geStart	Iniciar
geStop	Parar
geHealth	Verificar
geBadgeRunning	Em execução
geBadgeOn	Ligado
geBadgeOff	Desligado
geStatNode	Node.js
geStatInstall	Instalação
geStatPort	Porta de loopback
geStatHealth	Saúde
geRunning	em execução
geStopped	parado
geAbsent	ausente
geUnverified	não verificado
geNoPath	não vinculado
geStatePath	Diretório de instalação
geStateMode	Modo
geStateProcess	Processo local
geStateVerified	Última verificação
geStateError	Último erro
geModeExisting	Vincular uma instalação existente
geModePinned	Clonar uma versão fixada
geMode	Modo de instalação
geModeNote	O modo fixado clona um commit após um clique e exige a chave de download pela rede.
geMcpTitle	Ferramentas MCP
geMcpRegister	Registrar de novo
geMcpSync	Sincronizar ferramentas
geMcpUnregister	Cancelar registro
geMcpRegistered	registrado
geMcpOff	não registrado
geToolsIdle	As ferramentas aparecem aqui depois de iniciar e sincronizar
geToolRead	somente leitura
geToolWrite	escrita · aprovação
geConfigTitle	Programa e porta (configurado pelo proprietário)
geSwitch	Ativar o God's Eye View
geSwitchNote	Desligado por padrão. Salve a chave e os caminhos primeiro, depois pressione Iniciar; este nó nunca o executa na inicialização.
gePath	Diretório de instalação
gePathPlaceholder	~/Tools/gods-eye-view
gePathNote	Um caminho absoluto ou com ~; diretórios de sistema, do Keychain e de dados do nó são recusados.
geVersion	Versão fixada
geVersionNote	O package.json deve informar exatamente esta versão, caso contrário a inicialização é recusada.
gePort	Porta de loopback
gePortNote	Vinculada somente a 127.0.0.1; uma porta ocupada é recusada.
geNodePath	Executável do Node.js
geNodePlaceholder	vazio significa detecção automática
geNodeNote	Requer Node.js 20 ou superior; vazio usa o node do PATH.
gePull	Permitir um clone fixado único
gePullNote	Desligado por padrão; só o clique em Instalar faz a conexão, e o HEAD deve ser igual ao commit 40-hex.
geRepo	Repositório de origem (https)
geRepoNote	Sem credenciais, query ou fragmento.
geRef	Tag ou branch fixada
geRefNote	Usada junto com o commit; uma tag movida não pode mudar o que é executado.
geCommit	Commit fixado (40 hex)
geCommitNote	O HEAD do clone deve ser exatamente igual a ele.
geVerify	Verificar instalação
geInstall	Instalar / verificar
geInstallNote	O modo existente apenas verifica; o modo fixado clona em um diretório de preparação e substitui o destino somente depois de verificar.
geCredTitle	Feeds opcionais (Keychain do macOS)
geCredNote	Os valores vão somente para o Keychain; as configurações guardam referências, que se tornam variáveis de ambiente na inicialização e nunca aparecem na página, na auditoria ou em um snapshot.
geCredStore	Guardar no Keychain
geCredMissing	não guardada
geSourceOn	entregar ao programa local na inicialização
geCredEmpty	A credencial está vazia
geCredStored	Guardada no Keychain
geCredFailed	A credencial não foi guardada
geActionFailed	A ação falhou
geActionDone	Aceito
geSaveFirst	Salve as configurações antes de iniciar
dcStateFailed	falhou
dcStateOff	desligado
dcLabel	rótulo
dcUrl	URL
dcKindField	tipo
dcServer	id do servidor
dcTool	ferramenta
dcArgs	JSON de argumentos
hvRemove	remover
asTitle	Assistente privado
asDesc	Permissões unificadas de conectores e agendas locais. Toda escrita precisa da aprovação do proprietário em um cartão no celular ou neste console, e o executor verifica o recibo assinado.
asBadgeOn	ativo
asBadgeOff	desligado
asBadgePending	pendente
asStatPending	Pendentes
asStatPendingNote	nada é executado antes da aprovação
asStatDrafts	Rascunhos
asStatDraftsNote	o corpo fica neste Mac
asStatConnectors	Conectores ativos
asStatConnectorsNote	somente leitura ou proposta
asStatMail	E-mail
asMailReady	credenciais guardadas
asMailMissing	credenciais ausentes
asSwitchesTitle	Agendas locais
asSwitchNote	Desligado por padrão; salve e depois ative. A escolha sobrevive a uma reinicialização.
asMaster	Chave mestre do assistente
asBriefingSwitch	Resumo privado diário
asPatrolSwitch	Ronda dos dispositivos da casa
asMailSwitch	Triagem de e-mail somente leitura
asBriefHour	Hora do resumo
asBriefHourNote	horário local, 0–23
asBriefMinute	Minuto do resumo
asBriefMinuteNote	0–59
asPatrolInterval	Intervalo da ronda (minutos)
asPatrolIntervalNote	5–1440 minutos
asPatrolOffline	Limite de inatividade (minutos)
asPatrolOfflineNote	uma proposta só é feita após esse tempo
asImapHost	Host IMAP
asImapHostNote	somente TLS implícito, porta 993; sem descoberta
asImapPort	Porta IMAP
asSmtpHost	Host SMTP
asSmtpHostNote	somente TLS implícito, porta 465; sem sondagem
asSmtpPort	Porta SMTP
asPortNote	somente 993 e 465 são utilizáveis
asMailUser	Conta de e-mail
asMailUserNote	usada apenas para entrar, nunca registrada em log
asMailFrom	Endereço remetente
asMailFromNote	o remetente dos rascunhos de resposta
asLookback	Dias de retroatividade
asLookbackNote	1–14 dias
asMaxMessages	Mensagens por execução
asMaxMessagesNote	1–30 mensagens
asBriefingNow	Resumir agora
asPatrolNow	Fazer ronda agora
asMailNow	Triar e-mail agora
asSaveFirst	Salve e ative o assistente primeiro
asRunDone	Concluído
asRunFailed	A execução falhou
asConnectorsTitle	Permissões dos conectores
asConnectorsIdle	Ainda não montado
asConnectorsNote	ler coleta, propor rascunha; uma escrita precisa de um recibo assinado antes.
asPermRead	ler
asPermPropose	propor
asPermWrite	escrever
asPermAdmin	administrar
asKindCalendar	calendário
asKindCalDav	CalDAV
asKindSmartHome	casa inteligente
asKindMcp	MCP
asKindGodsEye	God's Eye View
asKindMail	e-mail
asKindOther	outro
asMailCredsTitle	Credenciais de e-mail (referências do Keychain)
asCredImap	Senha IMAP
asCredSmtp	Senha SMTP
asCredPlaceholder	senha específica de app
asCredStore	Guardar no Keychain
asCredStored	guardada
asCredMissing	ausente
asCredEmpty	Informe a senha
asCredFailed	A credencial não foi guardada
asCredNote	O valor vai somente para o Keychain do macOS; snapshots e o log de auditoria carregam a referência. Salve e ative o assistente primeiro.
asPendingTitle	Aprovações pendentes
asPendingIdle	Nada aguardando
asTtl	restante
asCancelAll	Cancelar todas as pendentes
asPendingNote	Os cartões trazem o alvo e o digest; o recibo é emitido no cartão do celular ou dentro deste nó.
asAuditTitle	Auditoria local (SQLite)
asAuditIdle	Nenhum registro ainda
asDecisionDone	Aplicada
asDecisionFailed	Não aplicada
asRepairsTitle	Dispositivos críticos e ações de reparo
asRepairOn	ativo
asRepairsEmpty	Nenhum dispositivo crítico registrado
asRepairsFull	O limite foi atingido
asRepairAdd	Adicionar regra
asRepairsNote	A ronda é somente leitura; um reparo roda uma vez, só após aprovação.
asInklingTitle	Inkling 2 Mini (local)
asInklingDesc	Inferência multimodal e de JSON estruturado no dispositivo, somente via 127.0.0.1. Os pesos nunca acompanham o instalador, e as imagens ficam neste Mac.
asInklingOff	desligado
asInklingUnknown	não sondado
asInklingReady	pronto
asInklingModelMissing	modelo não baixado
asInklingRuntimeMissing	sem runtime local
asInklingRefused	endpoint recusado
asInklingProbe	Sondar runtimes locais
asInklingEnable	Ativar o Inkling 2 Mini local
asInklingMultimodal	Leitura multimodal de tickets
asInklingJSON	Inferência de JSON estruturado
asInklingOllama	Endpoint do Ollama
asInklingMlx	Endpoint do MLX
asInklingEndpointNote	somente 127.0.0.1, localhost ou [::1]; qualquer outra coisa é recusada sem nenhuma requisição
asInklingModel	Referência do modelo
asInklingModelNote	o nome do modelo dentro do Ollama, ex. inkling-2-mini
asInklingTickets	Caminhos dos tickets (separados por vírgula)
asInklingTicketsNote	até 4, cada um dentro de um diretório de workspace autorizado
asInklingRuntime	runtime
asInklingStats	JSON / mídia / degradado
asInklingLastUsed	último uso
asInklingNever	nunca
asInklingPull	Baixar localmente: 
asInklingNote	O modelo apenas lê e propõe; envio, gravação em calendário ou controle da casa ainda exigem um recibo aprovado por uma pessoa.
opTitle	Operações e memória local
opDesc	Doctor, recordação episódica, memorandos de voz e o watchdog do sistema. Tudo permanece em 127.0.0.1 e nas contas já configuradas; escritas ainda exigem um recibo aprovado por uma pessoa.
opDoctorRun	Executar doctor completo
opDoctorNever	ainda não executado
opDoctorIdle	Use o botão acima; a saída é censurada e nenhum corpo de mensagem é lido.
opDoctorOk	ok
opDoctorWarning	alerta
opDoctorFailed	falhou
opDoctorSkipped	ignorado
opHistoryTitle	Memória episódica local (FTS5 selado)
opHistoryAsk	Pergunte sobre o passado, ex.: qual foi a última conta?
opHistoryRun	Perguntar ao histórico
opHistoryIndex	Indexar workspace
opHistoryNote	Títulos, corpos e fontes são selados com AES-GCM; o índice de texto completo só vê resumos HMAC dos tokens. Zero bytes saem deste Mac.
opHistoryEmpty	Nenhum registro indexado ainda; indexe um workspace ou gere um resumo primeiro.
opHistoryNoAnswer	Nada relevante foi encontrado
opQueryEmpty	Digite uma pergunta
opIndexDone	Indexação concluída
opVoiceTitle	Memorandos de voz (no dispositivo)
opVoiceIdle	Nenhum memorando de voz ainda. O áudio do celular se torna aprovações pendentes primeiro.
opVoiceNote	Fala no dispositivo da Apple ou whisper.cpp em 127.0.0.1; a transcrição fica em memória até que uma aprovação a grave.
opWatchTitle	Watchdog do sistema e abertura ao iniciar a sessão
opWatchInstall	Abrir ao iniciar a sessão
opWatchUninstall	Remover a abertura ao iniciar a sessão
opWatchCheck	Verificar agora
opWatchRefresh	Atualizar status
opWatchIdle	Nenhuma verificação registrada ainda
opWatchNote	O LaunchAgent usa argv fixos de loopback; saídas inesperadas reiniciam com backoff exponencial, e os alertas são deduplicados por 30 minutos e enviados ao celular.
opWatchInstalled	instalado
opWatchAbsent	não instalado
"""#

    /// 한국어 — translated in full 2026-11-27.
    private static let korean = #"""
brandSub	로컬 연산 및 물리 실행 허브 · 루프백 전용
brandClaim	Connect Everything. 모든 것을 연결해 지능이 자유롭게 협업하게 합니다.
brandSlogan	자유롭게 연결 · 비공개로 소통 · 지능적으로 협업
brandPosition	프라이버시 우선 지능형 연결 플랫폼
brandRole	프라이버시 우선 지능형 연결 플랫폼 POPOPX의 온디바이스 엣지 연산 및 프라이버시 실행 노드
brandMission	POPOPX는 단순히 연결 도구를 제공하지 않습니다 — 사람, AI, 에이전트, 기기, 서비스가 안전하게 연결되고 자유롭게 협업하는 개방형 생태계를 만듭니다.
loadingShort	불러오는 중
connecting	연결 중
live	연결됨
retryState	다시 연결 중
offline	오프라인
offlineBanner	노드와의 실시간 채널이 끊어졌습니다. 이 페이지는 마지막으로 성공적으로 읽은 스냅샷을 표시합니다.
retry	지금 다시 연결
langGroup	콘솔 언어
langFallback	아직 교정된 카탈로그가 없어 페이지가 영어로 유지됩니다 (브리핑과 스크립트는 선택한 언어를 계속 사용합니다)
langSaveHint	페이지는 전환되었습니다. 저장을 누르기 전까지 노드는 자체 언어 설정을 유지합니다
langSaveFailed	언어 설정을 저장하지 못했습니다. 노드가 사용하는 언어로 되돌아갑니다
railAria	설정 단계
s1	하드웨어 및 배포
s2	iPhone 페어링
s3	엔진 및 물리 권한
s1Title	1단계 · 하드웨어 스캔 및 원클릭 설치
s1Desc	Apple Silicon 프로파일을 읽고, 통합 메모리에 맞춰 모델 스택을 고르고, 이 Mac에 로컬 AI 엔진을 설치합니다.
s2Title	2단계 · iPhone 페어링
s3Title	3단계 · 열 개의 엔진과 물리 권한
s3Desc	스위치, 유휴 컴퓨트 공유, 물리 센티널, Chrono Ark. 모든 변경은 config/settings.json에 명시적으로 기록됩니다.
loading	첫 스냅샷을 기다리는 중…
loadFailed	노드 상태를 읽지 못했습니다
reloadRetry	다시 시도
noData	아직 데이터 없음
chip	칩
cores	CPU 코어
coresNote	성능 P · 효율 E
mem	통합 메모리
memNote	공유 Apple Silicon 풀
freeDisk	여유 SSD
freeDiskNote	전체 용량 대비
tier	컴퓨트 등급
loadTitle	실시간 부하
loadNote	샘플링 기준
memUsed	사용 중인 메모리
pressure	메모리 압력
processes	프로세스
cpu	CPU 부하
nominal	정상
warning	경고
critical	위험
memTitle	통합 메모리 게이지
usedOf	사용 / 총
toolchainTitle	툴체인 프로브
toolchainEmpty	노드가 아직 툴체인 프로브를 보고하지 않았습니다.
present	있음
missing	없음
stepsTitle	프로비저닝 체크리스트
stepsEmpty	아직 배포를 실행하지 않았습니다. 원클릭 배포를 눌러 시작하십시오.
logTitle	실시간 설치 로그
levelFilter	로그 레벨 필터
filterAll	모든 레벨
filterInfo	info 이상
filterNotice	notice 이상
filterWarning	warning 이상
filterError	error만
copyLog	로그 복사
clearLog	지우기
logCleared	화면을 지웠습니다 (노드 측 로그는 유지됨)
logLines	로그 줄
logLocked	자동 스크롤 일시 정지
logUnlock	자동 스크롤 재개
logEmpty	로그 창이 비어 있습니다. 배포가 실행되면 바로 스트리밍이 시작됩니다.
logCopied	로그를 복사했습니다
deploy	로컬 AI 엔진 원클릭 배포
cancelInstall	배포 취소
idleHint	brew / ffmpeg / uv / Ollama를 프로브하고, 메모리 등급에 맞는 가중치를 가져오며 LTX-2.5 워크스페이스를 준비합니다.
installing	배포 실행 중
phaseIdle	대기
phaseDetecting	감지 중
phaseProvisioning	프로비저닝 중
phasePullingLLM	LLM 가져오는 중
phasePreparingWorkspace	워크스페이스 준비 중
phaseDownloadingWeights	가중치 다운로드 중
phaseVerifying	검증 중
phaseReady	엔진 준비 완료
phaseFailed	배포 실패
phaseCancelled	취소됨
deployStarted	배포를 요청했습니다
deployFailed	배포를 시작하지 못했습니다
deployCancel	취소를 요청했습니다
deployCancelFailed	취소하지 못했습니다
installDone	로컬 엔진이 준비되었습니다
installFailedWhy	마지막 배포 실패
planTitle	권장 모델 래더
planNote	계획 근거
thBand	메모리 구간
thLLM	언어 모델
thVideo	영상 정밀도
thResident	상주
thNote	정책
tierCap	풀 정밀도 로컬
tierQuant	양자화 로컬
tierLight	경량 로컬
heavyLocal	무거운 영상은 로컬에서 렌더링
heavyMesh	무거운 영상은 메시로 라우팅
noPlan	노드가 아직 모델 계획을 생성하지 않았습니다.
modelTitle	모델 관리
modelDefault	기본 · 메모리 등급 기준
modelResident	예상 상주량
modelAdmission	메모리 허용
modelGguf	사용자 지정 GGUF
modelCopyPull	가져오기 명령 복사
modelSwapWarn	이 Mac은 스왑 한계선에 있거나 그 이하입니다. OOM 멈춤 위험을 감수하는 대신 무거운 로컬 작업을 거부합니다.
modelSwitched	로컬 모델을 전환했습니다
modelSwitchFailed	로컬 모델을 전환하지 못했습니다
modelUnpinned	하드웨어 등급으로 복귀
modelPinnedNote	고정됨 — 더 이상 메모리 등급을 따르지 않습니다
modelUnknown	이 모델은 카탈로그에 없으므로 메모리 수치는 여전히 등급 자체의 추정치입니다.
modelCardTitle	로컬 모델 및 경량 모드
modelMode	모드
modelModeLite	경량 · 모델 없음
modelModeEnhanced	AI 강화 · 준비됨
modelModeNoModel	AI 강화 · 가져오기 대기
modelPullBtn	지금 가져오기
modelPulling	가져오는 중…
modelCancelBtn	가져오기 취소
modelLiteOn	경량 모드로 전환
modelLiteOff	경량 모드 해제
modelProgress	가져오기 진행률
modelReadyLabel	로컬 모델 준비됨
modelFailed	가져오기가 끝나지 않았습니다
modelNone	가져올 모델이 없습니다
modelPullStarted	가져오기를 시작했습니다
modelPullFailed	가져오기 요청이 실패했습니다
modelBoundary	가져오기는 127.0.0.1의 로컬 Ollama를 통해서만 이루어집니다. 어떤 가중치도 설치 프로그램에 들어가거나 이 Mac을 떠나지 않습니다.
modelFeatureOff	경량 모드에서는 꺼짐
asMailPreset	메일 제공자 프리셋
asMailPresetNone	직접 입력
asMailPresetHint	제공자를 고르면 IMAPS/SMTPS 호스트와 포트가 채워집니다. 앱 전용 비밀번호를 사용하고 오른쪽 Keychain에 저장하십시오.
asMailPresetApplied	템플릿을 적용했습니다
qrTitle	페어링 QR
qrSub	iOS에서 스캔하십시오 · Discover → Mac Node 페어링. 암호화 터널은 같은 네트워크에서 열립니다.
qr	QR 코드
qrRetry	QR 다시 불러오기
qrLoading	QR을 렌더링하는 중…
qrLoadFailed	QR 이미지를 불러오지 못했습니다
noQR	노드가 지금은 QR 이미지를 렌더링할 수 없습니다. 아래의 암호화 링크는 여전히 유효하며 iOS에서 직접 붙여넣을 수 있습니다.
code	종단간 암호화 페어링 코드
copyCode	코드 복사
uri	/*PPX_SCHEME*/ 초대 URI
copyURI	URI 복사
pairLink	암호화 페어링 링크
copyLink	링크 복사
pairLinkNote	링크는 생태계 초대 형식으로 봉인되어 있어 시그널링 노드를 지칭하지 않습니다. QR에도 완전히 동일한 바이트가 담겨 있습니다.
pairDiagTitle	원시 페어링 자격 증명 (이 Mac 전용)
pairDiagNote	아래 코드와 초대 URI에는 SMP 큐 주소가 포함되어 있으며 문제 해결용입니다. 공유는 위의 암호화 링크로 하십시오.
pairDiagEmpty	아직 페어링 자격 증명이 없습니다. 오퍼를 재생성하면 원시 값이 여기에 나타납니다.
pubkey	노드 공개 키
expiry	유효 기간
expired	이 페어링 코드는 만료되었습니다
used	이 페어링 코드는 이미 사용되었습니다
oneTime	1회용
rotate	재생성
rotateFailed	페어링 오퍼를 재생성하지 못했습니다
noPairing	시그널링 게이트웨이가 아직 오퍼를 발급하지 않았습니다. 데몬이 올라오면 나타납니다.
tunnel	iPhone과의 암호화 터널이 연결되었습니다
tunnelSub	이 기기 키만 허용 목록에 있으며, 이 키만이 이 Mac의 열 개 엔진을 구동할 수 있습니다.
devices	페어링된 기기
devicesEmpty	아직 QR 핸드셰이크를 완료한 기기가 없습니다.
revoke	해지
revokeDone	기기를 해지했습니다
revokeFailed	해지에 실패했습니다
revokedRow	해지됨
deviceModel	모델
pairedAt	페어링 시각
lastSeen	마지막 확인
neverSeen	확인된 적 없음
copyPubkey	키 복사
bridgeTitle	SMP 시그널링 브리지
daemonStopped	데몬 중지됨
daemonStarting	데몬 시작 중
daemonRunning	데몬 실행 중
daemonDegraded	데몬 성능 저하
daemonMissing	popopx-chat 바이너리 없음
accepted	수락됨
rejected	거부됨
delivered	전달됨
outbox	발신함 적체
uptime	가동 시간
wsOn	WebSocket 연결됨
wsOff	WebSocket 끊김
daemonPath	데몬 경로
bridgeErr	마지막 오류
daemonInstall	popopx-chat이 설치되어 있지 않습니다 —— 내려받고 검증한 뒤 실행하십시오: curl -o- https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh > popopx-install.sh; shasum -a 256 popopx-install.sh (다이제스트는 README 설치 절에 있는 값과 같아야 하며, 다르면 스크립트를 실행하지 마십시오); bash popopx-install.sh는 실행 파일을 ~/.local/bin/popopx-chat로 설치합니다
enginesTitle	열 개의 비즈니스 엔진
enginesBadge	사용 중
enginesLoading	엔진 설명자를 기다리는 중…
runs	실행
failures	실패
artifacts	산출물
lastRun	마지막
busyNow	작업 중
idleNow	유휴
requires	필요
needsModels	로컬 모델 필요
deterministicFlag	결정적 · 모델 없음
toggleOn	켜짐
toggleOff	꺼짐
toggleFailed	스위치 요청이 실패했습니다
save	설정 저장
saving	저장 중…
saved	설정이 노드와 일치합니다
dirty	로컬 편집 내용이 저장되지 않았습니다
saveDone	설정을 기록했습니다
saveFailed	저장 실패
conflict	노드에 더 새로운 리비전이 있어 양식을 그 리비전으로 다시 불러왔습니다
revision	리비전
revert	버리기
reverted	노드 문서로 되돌렸습니다
meshTitle	유휴 컴퓨트 공유
meshOn	공유 켜짐
meshOff	공유 꺼짐
shareEnable	유휴 사이클 제공
maxMem	최대 메모리
maxMemHint	이 기기의 안전 상한
maxJobs	동시 작업 수
minFree	최소 여유 디스크 GB
ownerPresent	소유자가 있을 때만
windows	유휴 시간대
windowAdd	시간대 추가
windowRemove	제거
windowEmpty	시간대가 없으면 노드는 작업을 전혀 받지 않습니다.
from	시작
to	종료
weekdayShort	요일
acceptingNow	지금 수락 중
notAcceptingNow	지금 수락하지 않음
accrued	적립 포인트
settled	정산된 작업
activeJobs	활성 작업
nextWindow	다음 시간대
meshSandbox	샌드박스 바이트
sentinelTitle	물리 공간 센티널
sentinelSub	결정적 잠금: 루프에 모델이 없으며 🔒 / LOCK_ALL에서 즉시 작동합니다.
sentinelOn	센티널 무장됨
sentinelOff	센티널 꺼짐
mounts	마운트 해제할 볼륨
mountAdd	경로 추가
mountEmpty	구성된 마운트 경로가 없습니다. 잠금은 클립보드 지우기, 화면 잠금, 웹훅 호출만 수행합니다.
mountHint	예: /Volumes/ENCRYPTED 또는 smb://… (잠금 시 diskutil로 마운트 해제)
clipboard	잠금 시 클립보드 지우기
lockScreen	화면 잠금
sleepDisplays	디스플레이 잠자기
phrases	트리거 문구 (쉼표로 구분)
hookUrl	Home Assistant / 웹훅 URL
hookSecret	웹훅 서명 비밀
secretShow	표시
secretHide	숨기기
drill	지금 드릴 실행
drillDone	드릴 영수증이 반환되었습니다
drillFailed	드릴 실패
drillPending	드릴 실행 중…
drillTitle	결정적 잠금 영수증
receiptEmpty	아직 잠금 기록이 없습니다. 지금 드릴 실행을 눌러 하나를 생성하십시오.
modelFree	제로 모델
modelUsed	모델 개입 (예상 밖)
receiptTrigger	트리거
receiptClip	클립보드
receiptUnmount	마운트 해제됨
receiptMountFail	마운트 실패
receiptScreen	화면
receiptWebhook	웹훅
receiptElapsed	소요 시간
arkTitle	Chrono Ark
arkSub	암호학적 타임록과 놓친 박동 보호. 예정된 시간이나 침묵 후에 열립니다.
arkOk	보호자 정상
arkAlert	하트비트 지연
beat	하트비트 간격 (시간)
missed	허용 누락 박동
graceDue	공개 기한
lockDur	타임록 (초)
lockDays	약
daysUnit	일
unlocks	최초 해제 시각
directory	암호화 아카이브 디렉터리
dirHint	노드가 vault/sealed/로 고정하며, chrono_ark가 캡슐을 쓰는 곳도 바로 여기입니다
dirReveal	Finder에서 보기
dirUnsupported	페이지는 로컬 디렉터리를 나열하거나 이 경로를 변경할 수 없습니다. “Finder에서 보기”는 노드가 이 기기에서 실행합니다.
revealFailed	노드가 아카이브 폴더를 열지 못했습니다
archives	봉인된 아카이브
archivesEmpty	아직 봉인된 것이 없습니다.
archiveSealedAt	봉인
archiveOpens	열림
archiveRounds	라운드
archiveFingerprint	키 지문
archiveOpen	잠금 경과
archiveSealed	아직 봉인 상태
beneficiary	수혜자 이름
beneficiaryQueue	수혜자 대기열
devTitle	개발자 서랍
devHint	원시 스냅샷 JSON 및 와이어 명령 주입
devOpen	펼치기
devClose	접기
rawFetch	원시 스냅샷 가져오기
rawCopy	JSON 복사
rawEmpty	아직 가져오지 않았습니다.
rawFailed	가져오기 실패
rawTruncated	표시용으로 잘림
cmdLabel	::popopx_sys::NODE_CMD 명령 주입
cmdHint	형식: ::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}. iOS 명령이 지나는 것과 동일한 경로를 사용합니다.
cmdSend	실행
cmdClear	출력 지우기
cmdEmpty	먼저 명령을 입력하십시오
cmdDone	명령을 실행했습니다
cmdFailed	명령 실패
copyDone	클립보드에 복사했습니다
copyFailed	복사 실패
loopbackNote	페이지와 API는 127.0.0.1에서만 제공됩니다. 외부 스크립트, 글꼴, 추적기는 없습니다.
unknown	알 수 없음
yes	예
no	아니요
never	없음
secondsUnit	초
ago	전
paired	페어링됨
released	해제됨
now	지금
s4	프라이버시 브리지
s4Title	프라이버시 브리지 및 수동 확인
s4Desc	원시 캘린더 및 워크스페이스 데이터는 이 Mac에서만 읽힙니다. 여기에 나열되는 것은 노드 자체의 다이제스트와 사용자를 기다리는 작업입니다.
pvGuarantee	이 페이지의 모든 내용은 루프백 스냅샷에서 나옵니다. 일정 제목, 장소, 참석자, 파일 본문은 인코딩 전에 폐기되며, 모든 쓰기는 여기 또는 페어링된 휴대폰에서 두 번째 확인을 거칩니다.
pvAccessTitle	권한 스위치
pvAuthNote	스위치는 노드 자체의 승인입니다. macOS가 캘린더 접근을 별도로 거부할 수 있으므로 시스템 상태를 아래에 표시합니다.
pvCalSwitch	캘린더 여유/바쁨 슬롯 읽기 (일정 내용 아님)
pvReadSwitch	승인된 디렉터리 안의 파일 요약
pvWriteSwitch	승인된 디렉터리 안에 쓰기 (매번 확인)
pvNotifySwitch	제안이 도착하면 알림 센터에서 알림
pvAskAccess	macOS에 캘린더 접근 요청
pvAuthAgain	macOS에 다시 요청
pvAuthAsked	macOS에서 권한 상태를 갱신했습니다
pvAuthAskFailed	접근 요청이 실패했습니다
pvCheck	향후 7일 자체 점검
pvCheckOff	캘린더 브리지가 꺼져 있어 쿼리를 보내지 않습니다
pvCheckFree	여유 슬롯을 찾았습니다
pvCheckNone	이 구간 안에 여유 슬롯이 없습니다
pvCheckFailed	자체 점검이 거부되었습니다
pvDirsTitle	승인된 디렉터리
pvDirAdd	디렉터리 추가
pvDirRemove	제거
pvDirHint	사용자 경로 형식으로 입력하십시오. 예: ~/Documents/Projects. 노드는 처음 세 개만 유지하며 그 안에서만 읽습니다.
pvDirEmpty	아직 디렉터리가 없습니다. 요약과 쓰기가 모두 거부됩니다.
pvDirMax	디렉터리 상한에 도달했습니다. 먼저 하나를 제거하십시오
pvDirOpen	존재하고 접근 가능
pvDirClosed	없거나 접근 불가
pvDirsKnown	노드가 실제로 수락하고 해석하는 디렉터리
pvDirsKnownNote	이 열은 입력 상자가 아니라 노드의 응답입니다. 저장 후에만 일치하며, 항목이 빠졌다면 상한을 넘은 것입니다.
pvDirNoneSaved	노드가 수락한 디렉터리가 없습니다
pvRulesTitle	여유 슬롯 규칙 및 제안 기본값
pvWorkStart	업무 시작
pvWorkEnd	업무 종료
pvDuration	기본 길이 (분)
pvBuffer	앞뒤 여유 (분)
pvLunchStart	점심 시작
pvLunchEnd	점심 종료
pvBlockLunch	점심을 바쁨으로 처리
pvWorkdays	근무일
pvZone	시간대
pvZoneNote	비워 두면 Mac의 현재 시간대를 사용합니다.
pvCallTemplate	통화 링크 템플릿
pvCallNote	{ref}와 {node}가 치환됩니다. 비워 두면 제안에 링크가 포함되지 않습니다.
pvPropTitle	사용자를 기다리는 제안
pvBookTitle	이 노드가 생성한 예약
pvAuditTitle	로컬 감사 기록
pvAuditCopy	기록 복사
pvNone	결정을 기다리는 항목 없음
pvNoBookings	이 노드는 아직 캘린더 일정을 쓰지 않았습니다
pvNoAudit	아직 항목 없음
pvStatPending	대기 중
pvStatBookings	예약
pvStatDirs	접근 가능 디렉터리
pvStatDirsNote	접근 가능 / 상한
pvBadgePending	확인 대기
pvBadgeQuiet	확인할 항목 없음
pvActCreate	일정 생성
pvActReschedule	일정 변경
pvActCancel	일정 취소
pvActWrite	파일 쓰기
pvActOrganize	파일 정리
pvActInvoke	도구 호출
pvStatePending	확인 대기
pvStateApproved	승인됨
pvStateExecuted	실행됨
pvStateRejected	거부됨
pvStateExpired	만료됨
pvStateFailed	실행 실패
pvStateCancelled	무효화됨
pvDomainCal	캘린더
pvDomainWs	워크스페이스
pvDomainMCP	MCP
pvDomainHome	홈
pvApprove	승인 후 실행
pvReject	거부
pvConfirmAgain	한 번 더 클릭하여 확인
pvCannotApprove	실행할 수 없습니다: 필요한 스위치나 디렉터리가 꺼져 있습니다
pvTtlOver	시간 초과
decisionDone	결정이 적용되었습니다
decisionFailed	결정을 적용하지 못했습니다
s5	엣지 허브 브리지
s5Title	로컬 검색 및 프로토콜 브리지
s5Desc	이 Mac과 사용자가 나열한 사설 주소만 프로브합니다. 모든 기능은 꺼진 상태로 시작하며, 켜져 있어도 동일한 2차 확인 게이트를 거칩니다.
hvGuarantee	여기의 모든 것은 루프백 주소에서 제공됩니다: 외부 송신도, 포트 스윕도, 호스트 추측도 없습니다. 공개 대상은 소켓이 생기기 전에 거부되며, 개수와 사유가 나열됩니다.
hvDiscTitle	로컬 기능 검색
hvDiscIdle	아직 측정된 항목 없음
hvScan	지금 프로브
hvScanning	측정 중
hvScanFailed	프로브가 실패했습니다
hvBoundary	루프백 + 소유자가 나열한 LAN 대상
hvKindEngine	엔진
hvKindModel	모델
hvKindWorkspace	워크스페이스
hvKindCalendar	캘린더
hvKindLan	LAN
hvKindRefused	거부됨
hvStatePresent	있음
hvStateAbsent	없음
hvStateInstalled	설치됨
hvStateAuthorized	승인됨
hvStateDenied	macOS에서 거부
hvStateOff	꺼짐
hvStateReachable	접근 가능
hvStateSilent	무응답
hvStateRefused	거부됨
hvStateFull	권한 있음
hvStateWrite	쓰기 전용
hvStateRestricted	제한됨
hvStateNotAsked	아직 요청 안 함
hvStateNoBridge	연결 안 됨
hvStatCaps	기능
hvStatRefused	거부된 대상
hvStatRefusedNote	연결 시도 없음
hvStatServers	MCP 서버
hvStatServersNote	등록됨 / 연결됨
hvStatEntities	표시되는 엔터티
hvStatEntitiesNote	허용 목록 기준
hvBadgePending	확인 대기
hvBadgeOn	브리지 켜짐
hvBadgeOff	모두 꺼짐
hvPropTitle	사용자를 기다리는 브리지 작업
hvPropNone	결정을 기다리는 브리지 작업이 없습니다
hvSwitchTitle	브리지 스위치 (기본값 모두 꺼짐)
hvSwitchNote	스위치는 뒤에 받쳐 주는 것이 있어야 효력이 있습니다. 등록된 MCP 서버, Home Assistant 또는 브로커 주소, CalDAV 서버가 없으면 노드는 꺼진 것으로 간주합니다.
hvMcpSwitch	로컬 MCP 클라이언트 사용 (stdio 또는 루프백 HTTP)
hvHomeSwitch	Home Assistant 및 MQTT 사용 (사설 네트워크 전용)
hvCalDavSwitch	CalDAV 여유/바쁨 사용 (시간대만, 일정 내용은 절대 아님)
hvAutoScan	콘솔을 열면 로컬 기능 프로브
hvReadonly	스마트 홈 읽기 전용: 상태만 미러링하고 절대 작동하지 않음
hvTelemetry	MQTT 텔레메트리 수락 (토픽 필터 필요)
hvStatusTitle	브리지 상태
hvStatusIdle	아직 요청 안 함
hvChecking	요청 중
hvRefresh	다시 요청
hvGateNote	세 줄 모두 페어링된 휴대폰이 쓰는 것과 동일한 도구 진입점에서 나옵니다. 읽기 전용 호출은 실행되고, 상태를 바꾸는 것은 제안이 되어 로컬 감사 로그에 기록됩니다.
hvBridgeMCP	MCP 클라이언트
hvBridgeHome	Home Assistant · MQTT
hvBridgeCalDav	CalDAV 여유/바쁨
hvHaOk	Home Assistant 구성됨
hvHaAbsent	Home Assistant 없음
hvMqttOk	브로커 연결됨
hvMqttAbsent	브로커 연결 안 됨
hvRejectedEntries	거부된 레지스트리 항목
hvHaUrl	Home Assistant URL
hvHaNote	루프백, 10/8, 172.16/12, 192.168/16, .local만 허용됩니다. 공개 주소나 외부 도메인은 소켓이 생기기 전에 거부됩니다.
hvHaToken	장기 액세스 토큰 (Keychain)
hvMqttHost	MQTT 호스트
hvMqttHostPlaceholder	예: 192.168.1.20
hvMqttNote	동일한 사설 네트워크 경계입니다. 노드가 MQTT v3.1.1을 직접 사용하며 중간에 제3자가 없습니다.
hvMqttPassword	MQTT 비밀번호 (Keychain)
hvSecretSave	Keychain에 저장
hvSecretStored	자격 증명이 암호화되어 저장되었습니다
hvMqttPort	MQTT 포트
hvSecretFailed	자격 증명이 저장되지 않았습니다
hvSecretEmpty	먼저 자격 증명을 입력하십시오
hvServerRequired	먼저 CalDAV 서버를 지정하십시오
hvCalDavId	CalDAV 서버 ID
hvCalDavIdNote	설정 문서에 이미 나열된 서버와 일치해야 합니다.
hvCalDavPassword	CalDAV 비밀번호 또는 앱 토큰
hvCalDavPasswordNote	다시 말하지만 참조만 저장합니다. 노드는 이 값을 설정 파일, 로그 줄, 또는 이 페이지가 읽는 어떤 응답에도 넣지 않습니다.
hvEntitiesTitle	엔터티 허용 목록
hvEntityAdd	엔터티 추가
hvEntityNote	여기에 나열되지 않은 엔터티는 이 노드에 존재하지 않습니다. 잠금, 경보, 사이렌, 카메라, 로봇청소기는 나열되어 있어도 2차 확인이 필요합니다.
hvEntityEmpty	허용 목록이 비어 있어 브리지가 꺼진 것으로 표시됩니다
hvEntityLimit	허용 목록이 상한에 도달했습니다
hvTargetsTitle	LAN 프로브 대상 (선택 사항)
hvTargetAdd	대상 추가
hvTargetNote	호스트와 포트. 350 ms 타임아웃의 TCP 시도 1회이며, 공개 주소는 거부되어 위의 거부된 대상에 집계됩니다.
hvTargetEmpty	나열된 대상이 없어 이 Mac만 프로브합니다
hvTargetLimit	프로브 목록이 상한에 도달했습니다
upTitle	서명된 업데이트
upDesc	소유자가 고정한 HTTPS 매니페스트 하나만 가져옵니다. 서명이 잘못되었거나 더 새롭지 않은 버전은 카드 없이 무시됩니다.
upCheck	업데이트 확인
upChecking	확인 중
upCheckFailed	확인에 실패했습니다
upFound	새 버전을 사용할 수 있습니다
upUpToDate	이미 최신입니다
upIgnored	조용히 무시됨
upFailed	업데이트 작업이 실패했습니다
upDone	완료
upBadgeReady	확인 대기
upBadgeOn	업데이트 켜짐
upBadgeIncomplete	불완전
upBadgeOff	업데이트 꺼짐
upCurrent	현재 버전
upKey	매니페스트 키
upLastCheck	마지막 확인
upInstalled	설치됨
upPendingTitle	설치 준비 완료
upNoPending	결정을 기다리는 릴리스가 없습니다
upBuild	빌드
upReleased	출시
upPackage	패키지
upSummary	새로운 점
upApprove	지금 업데이트
upSnooze	나중에 알림
upConfirmAgain	한 번 더 클릭하여 확인
upRefused	거부됨
upConfigTitle	업데이트 피드 (소유자 구성)
upSwitchNote	매니페스트와 키를 모두 직접 제공합니다. 노드는 매니페스트 호스트에서 키를 가져오지 않으며 리디렉션도 따르지 않습니다.
upEnabled	서명된 업데이트 확인 사용
upManifestURL	매니페스트 URL
upManifestNote	입력한 호스트와 정확히 일치하는 443 포트의 https여야 하며, 모든 리디렉션은 거부됩니다.
upPublicKey	Ed25519 공개 키 (base64url)
upKeyNote	32바이트 키입니다. 지문이 위 통계에 표시되며 검증에는 이 값만 사용됩니다.
upPackageHosts	허용 패키지 호스트 (쉼표로 구분)
upPackageNote	매니페스트 호스트는 항상 허용됩니다. 서명된 매니페스트가 가리킬 수 있는 추가 호스트만 나열하십시오 (예: CDN).
upInterval	확인 간격 (분)
upSnoozeHours	미루기 기간 (시간)
upGateNote	감지는 자동이지만 설치는 아닙니다. 지금 업데이트를 누르기 전에는 아무것도 내려받지 않으며, 내려받은 패키지는 macOS가 열기 전에 바이트 크기와 SHA-256을 검사합니다.
dcFeedTitle	최신 항목
dcEmpty	아직 항목이 없습니다. 새로고침을 누르십시오
dcRefresh	지금 새로고침
dcRefreshing	새로고침 중
dcRefreshFailed	새로고침에 실패했습니다
dcRefreshNote	카드에는 읽을 수 있는 인덱스가 담기고, 서명된 페이로드는 feed.json으로 동일한 암호화 세션에서 전달되어 로컬 감사 로그에 기록됩니다.
dcConfigTitle	애그리게이터 설정
dcSwitchNote	기본값은 꺼짐입니다. 켜져 있어도 폴더, 피드, MCP 소스가 없으면 꺼진 것으로 표시됩니다.
dcEnabled	Discover 애그리게이터 사용
dcBadgeOn	애그리게이터 켜짐
dcBadgeOff	애그리게이터 꺼짐
dcInterval	새로고침 간격 (분)
dcMaxItems	실행당 최대 항목 수
dcFoldersTitle	로컬 폴더 (텍스트 전용)
dcFolderAdd	폴더 추가
dcFolderNote	홈 폴더 아래의 일반 텍스트 파일만 읽습니다. 심볼릭 링크, 너무 큰 파일, 너무 깊이 중첩된 폴더는 건너뜁니다.
dcFolderEmpty	추가된 폴더 없음
dcFolderLimit	폴더 목록이 상한에 도달했습니다
dcFeedsTitle	RSS / JSON 피드 (사설 네트워크 전용)
dcFeedAdd	피드 추가
dcFeedOn	켜짐
dcFeedNote	공개 주소는 소켓이 생기기 전에 EdgeBoundary에서 거부되며 아래 소스 상태에 표시됩니다.
dcFeedEmpty	추가된 피드 없음
dcFeedLimit	피드 목록이 상한에 도달했습니다
dcMcpTitle	읽기 전용 MCP 소스
dcMcpAdd	MCP 소스 추가
dcMcpNote	읽기 전용 도구만 사용합니다. 상태를 바꾸는 도구는 애그리게이터가 절대 실행하지 않습니다.
dcMcpEmpty	추가된 MCP 소스 없음
dcMcpLimit	MCP 목록이 상한에 도달했습니다
dcSourcesTitle	소스 상태
dcSourcesIdle	아직 실행 안 함
dcSourcesNote	모든 실행은 로컬 감사 로그에 기록되며, 전달은 여전히 바인딩된 종단간 세션을 사용합니다.
dcStatItems	항목
dcStatSources	소스
dcStatLastRun	마지막 실행
dcStatDelivered	마지막 전달
dcKindFolder	폴더
dcKindRSS	RSS / Atom
dcKindJSON	JSON 피드
dcKindMCP	MCP
dcStateOk	정상
dcStateRefused	거부됨
geTitle	글로벌 인텔리전스 맵 (God's Eye View)
geDesc	사용자가 이 Mac에 직접 설치하고 실행하는 별도의 타사 프로그램입니다. 이 노드는 고정된 버전을 검증하고, 127.0.0.1에서 실행하고, 검증된 MCP 항목을 읽기 우선 도구로 등록할 뿐입니다.
geStart	시작
geStop	중지
geHealth	확인
geBadgeRunning	실행 중
geBadgeOn	켜짐
geBadgeOff	꺼짐
geStatNode	Node.js
geStatInstall	설치
geStatPort	루프백 포트
geStatHealth	상태
geRunning	실행 중
geStopped	중지됨
geAbsent	없음
geUnverified	미검증
geNoPath	바인딩 없음
geStatePath	설치 디렉터리
geStateMode	모드
geStateProcess	로컬 프로세스
geStateVerified	마지막 검증
geStateError	마지막 오류
geModeExisting	기존 설치에 바인딩
geModePinned	고정 버전 클론
geMode	설치 모드
geModeNote	고정 모드는 클릭 한 번으로 커밋 하나를 클론하며 네트워크 가져오기 스위치가 필요합니다.
geMcpTitle	MCP 도구
geMcpRegister	다시 등록
geMcpSync	도구 동기화
geMcpUnregister	등록 해제
geMcpRegistered	등록됨
geMcpOff	등록되지 않음
geToolsIdle	시작과 동기화 후에 도구가 여기에 표시됩니다
geToolRead	읽기 전용
geToolWrite	쓰기 · 승인 필요
geConfigTitle	프로그램 및 포트 (소유자 구성)
geSwitch	God's Eye View 사용
geSwitchNote	기본값은 꺼짐입니다. 먼저 스위치와 경로를 저장한 뒤 시작을 누르십시오. 이 노드는 부팅 시 절대 실행하지 않습니다.
gePath	설치 디렉터리
gePathPlaceholder	~/Tools/gods-eye-view
gePathNote	절대 경로 또는 ~ 경로입니다. 시스템, Keychain, 노드 데이터 디렉터리는 거부됩니다.
geVersion	고정 버전
geVersionNote	package.json이 정확히 이 버전을 보고하지 않으면 시작이 거부됩니다.
gePort	루프백 포트
gePortNote	127.0.0.1에만 바인딩되며, 사용 중인 포트는 거부됩니다.
geNodePath	Node.js 실행 파일
geNodePlaceholder	비워 두면 자동 감지
geNodeNote	Node.js 20 이상이 필요하며, 비워 두면 PATH의 node를 사용합니다.
gePull	1회 한정 고정 클론 허용
gePullNote	기본값은 꺼짐입니다. 설치를 클릭할 때만 외부로 연결하며, HEAD는 40-hex 커밋과 같아야 합니다.
geRepo	소스 저장소 (https)
geRepoNote	자격 증명, 쿼리, 프래그먼트 없음.
geRef	고정 태그 또는 브랜치
geRefNote	커밋과 함께 사용합니다. 태그가 이동해도 실행되는 내용은 바뀌지 않습니다.
geCommit	고정 커밋 (40 hex)
geCommitNote	클론의 HEAD가 정확히 일치해야 합니다.
geVerify	설치 검증
geInstall	설치 / 검증
geInstallNote	기존 모드는 검증만 합니다. 고정 모드는 스테이징 디렉터리로 클론하고 검증을 통과한 뒤에만 대상을 교체합니다.
geCredTitle	선택적 피드 (macOS Keychain)
geCredNote	값은 Keychain에만 저장됩니다. 설정에는 참조가 남고, 이는 실행 시 환경 변수가 되며 페이지, 감사, 스냅샷에는 절대 나타나지 않습니다.
geCredStore	Keychain에 저장
geCredMissing	저장 안 됨
geSourceOn	실행 시 로컬 프로그램에 전달
geCredEmpty	자격 증명이 비어 있습니다
geCredStored	Keychain에 저장됨
geCredFailed	자격 증명이 저장되지 않았습니다
geActionFailed	작업이 실패했습니다
geActionDone	수락됨
geSaveFirst	시작 전에 설정을 저장하십시오
dcStateFailed	실패
dcStateOff	꺼짐
dcLabel	레이블
dcUrl	URL
dcKindField	종류
dcServer	서버 ID
dcTool	도구
dcArgs	인수 JSON
hvRemove	제거
asTitle	프라이빗 어시스턴트
asDesc	통합 커넥터 권한과 로컬 스케줄. 모든 쓰기는 휴대폰 카드나 이 콘솔에서 소유자의 승인이 필요하며, 실행기가 서명된 영수증을 검증합니다.
asBadgeOn	켜짐
asBadgeOff	꺼짐
asBadgePending	대기
asStatPending	대기 중
asStatPendingNote	승인 전에는 아무것도 실행되지 않습니다
asStatDrafts	초안
asStatDraftsNote	본문은 이 Mac에 남습니다
asStatConnectors	커넥터 켜짐
asStatConnectorsNote	읽기 또는 제안만
asStatMail	메일
asMailReady	자격 증명 저장됨
asMailMissing	자격 증명 없음
asSwitchesTitle	로컬 스케줄
asSwitchNote	기본값은 꺼짐입니다. 저장한 뒤 활성화하십시오. 선택은 재시작 후에도 유지됩니다.
asMaster	어시스턴트 마스터 스위치
asBriefingSwitch	일일 프라이빗 브리핑
asPatrolSwitch	홈 기기 순찰
asMailSwitch	읽기 전용 메일 분류
asBriefHour	브리핑 시
asBriefHourNote	로컬 시간, 0–23
asBriefMinute	브리핑 분
asBriefMinuteNote	0–59
asPatrolInterval	순찰 간격 (분)
asPatrolIntervalNote	5–1440분
asPatrolOffline	오프라인 임계값 (분)
asPatrolOfflineNote	이 시간이 지난 뒤에만 제안이 만들어집니다
asImapHost	IMAP 호스트
asImapHostNote	암시적 TLS 전용, 포트 993, 검색 없음
asImapPort	IMAP 포트
asSmtpHost	SMTP 호스트
asSmtpHostNote	암시적 TLS 전용, 포트 465, 프로빙 없음
asSmtpPort	SMTP 포트
asPortNote	993과 465만 사용할 수 있습니다
asMailUser	메일 계정
asMailUserNote	로그인에만 사용되며 기록되지 않습니다
asMailFrom	보낸 사람 주소
asMailFromNote	답장 초안의 보낸 사람
asLookback	조회 기간 (일)
asLookbackNote	1–14일
asMaxMessages	실행당 메시지 수
asMaxMessagesNote	1–30개 메시지
asBriefingNow	지금 브리핑
asPatrolNow	지금 순찰
asMailNow	지금 메일 분류
asSaveFirst	먼저 어시스턴트를 저장하고 활성화하십시오
asRunDone	완료
asRunFailed	실행이 실패했습니다
asConnectorsTitle	커넥터 권한
asConnectorsIdle	아직 조립되지 않음
asConnectorsNote	읽기는 수집하고, 제안은 초안을 만듭니다. 쓰기는 먼저 서명된 영수증이 필요합니다.
asPermRead	읽기
asPermPropose	제안
asPermWrite	쓰기
asPermAdmin	관리
asKindCalendar	캘린더
asKindCalDav	CalDAV
asKindSmartHome	스마트 홈
asKindMcp	MCP
asKindGodsEye	God's Eye View
asKindMail	메일
asKindOther	기타
asMailCredsTitle	메일 자격 증명 (Keychain 참조)
asCredImap	IMAP 비밀번호
asCredSmtp	SMTP 비밀번호
asCredPlaceholder	앱 전용 비밀번호
asCredStore	Keychain에 저장
asCredStored	저장됨
asCredMissing	없음
asCredEmpty	비밀번호를 입력하십시오
asCredFailed	자격 증명이 저장되지 않았습니다
asCredNote	값은 macOS Keychain에만 저장되며, 스냅샷과 감사 로그에는 참조가 남습니다. 먼저 어시스턴트를 저장하고 활성화하십시오.
asPendingTitle	대기 중인 승인
asPendingIdle	대기 중인 항목 없음
asTtl	남음
asCancelAll	대기 중인 항목 모두 취소
asPendingNote	카드에는 대상과 다이제스트가 담기며, 영수증은 휴대폰 카드나 이 노드 내부에서 발급됩니다.
asAuditTitle	로컬 감사 (SQLite)
asAuditIdle	아직 항목 없음
asDecisionDone	적용됨
asDecisionFailed	적용되지 않음
asRepairsTitle	중요 기기 및 복구 작업
asRepairOn	켜짐
asRepairsEmpty	등록된 중요 기기 없음
asRepairsFull	한도에 도달했습니다
asRepairAdd	규칙 추가
asRepairsNote	순찰은 읽기 전용입니다. 복구는 승인 후 한 번만 실행됩니다.
asInklingTitle	Inkling 2 Mini (로컬)
asInklingDesc	127.0.0.1에서만 이루어지는 온디바이스 멀티모달 및 구조화 JSON 추론. 가중치는 설치 프로그램에 포함되지 않으며 이미지는 이 Mac에 남습니다.
asInklingOff	꺼짐
asInklingUnknown	프로브 안 됨
asInklingReady	준비됨
asInklingModelMissing	모델을 가져오지 않음
asInklingRuntimeMissing	로컬 런타임 없음
asInklingRefused	엔드포인트 거부됨
asInklingProbe	로컬 런타임 프로브
asInklingEnable	로컬 Inkling 2 Mini 사용
asInklingMultimodal	멀티모달 티켓 읽기
asInklingJSON	구조화 JSON 추론
asInklingOllama	Ollama 엔드포인트
asInklingMlx	MLX 엔드포인트
asInklingEndpointNote	127.0.0.1, localhost, [::1]만 허용되며 그 외에는 요청 한 건도 보내지 않고 거부합니다
asInklingModel	모델 참조
asInklingModelNote	Ollama 내부의 모델 이름, 예: inkling-2-mini
asInklingTickets	티켓 경로 (쉼표로 구분)
asInklingTicketsNote	최대 4개, 각각 승인된 워크스페이스 디렉터리 안에 있어야 합니다
asInklingRuntime	런타임
asInklingStats	JSON / 미디어 / 성능 저하
asInklingLastUsed	마지막 사용
asInklingNever	없음
asInklingPull	로컬로 가져오기: 
asInklingNote	모델은 읽기와 제안만 합니다. 발송, 캘린더 쓰기, 홈 제어에는 여전히 사람이 승인한 영수증이 필요합니다.
opTitle	운영 및 로컬 메모리
opDesc	닥터, 에피소딕 회상, 음성 메모, 시스템 워치독. 모든 것은 127.0.0.1과 이미 구성된 계정에 머물며, 쓰기에는 여전히 사람이 승인한 영수증이 필요합니다.
opDoctorRun	전체 스택 닥터 실행
opDoctorNever	아직 실행 안 함
opDoctorIdle	위 버튼을 사용하십시오. 출력은 마스킹되며 메시지 본문은 읽지 않습니다.
opDoctorOk	정상
opDoctorWarning	경고
opDoctorFailed	실패
opDoctorSkipped	건너뜀
opHistoryTitle	로컬 에피소딕 메모리 (봉인된 FTS5)
opHistoryAsk	과거에 대해 물어보십시오. 예: 마지막 청구서는 무엇이었나요?
opHistoryRun	기록에 질문
opHistoryIndex	워크스페이스 인덱싱
opHistoryNote	제목, 본문, 출처는 AES-GCM으로 봉인되며, 전문 인덱스는 HMAC 토큰 다이제스트만 봅니다. 어떤 바이트도 이 Mac을 떠나지 않습니다.
opHistoryEmpty	아직 인덱싱된 항목이 없습니다. 워크스페이스를 인덱싱하거나 먼저 브리핑을 실행하십시오.
opHistoryNoAnswer	관련 내용을 찾지 못했습니다
opQueryEmpty	질문을 입력하십시오
opIndexDone	인덱싱 완료
opVoiceTitle	음성 메모 (온디바이스)
opVoiceIdle	아직 음성 메모가 없습니다. 휴대폰의 오디오는 먼저 대기 중인 승인이 됩니다.
opVoiceNote	Apple 온디바이스 음성 인식 또는 127.0.0.1 whisper.cpp를 사용합니다. 승인이 기록하기 전까지 전사 내용은 메모리에만 남습니다.
opWatchTitle	시스템 워치독 및 로그인 시 실행
opWatchInstall	로그인 시 실행
opWatchUninstall	로그인 시 실행 제거
opWatchCheck	지금 확인
opWatchRefresh	상태 새로고침
opWatchIdle	아직 기록된 점검 없음
opWatchNote	LaunchAgent는 고정된 루프백 argv를 사용합니다. 예기치 않은 종료는 지수 백오프로 재시작하며, 알림은 30분간 중복 제거되어 휴대폰으로 전송됩니다.
opWatchInstalled	설치됨
opWatchAbsent	설치 안 됨
"""#

    /// العربية — translated in full 2026-11-27; the page flips to `dir="rtl"` for this catalog.
    private static let arabic = #"""
brandSub	مركز الحوسبة المحلية والتنفيذ الفيزيائي · على loopback فقط
brandClaim	Connect Everything. نصل كل شيء، ليتعاون الذكاء بحرية.
brandSlogan	اتصال حر · تواصل خاص · تعاون ذكي
brandPosition	منصة الاتصال الذكية التي تضع الخصوصية أولا
brandRole	عقدة الحوسبة الطرفية والتنفيذ الخصوصي على الجهاز في POPOPX، منصة الاتصال الذكية التي تضع الخصوصية أولا
brandMission	لا تكتفي POPOPX بأدوات اتصال، بل تبني منظومة مفتوحة يتصل فيها الناس والذكاء الاصطناعي والوكلاء والأجهزة والخدمات بأمان ويتعاونون بحرية.
loadingShort	يتم التحميل
connecting	يتم الاتصال
live	متصل
retryState	إعادة الاتصال
offline	غير متصل
offlineBanner	انقطع الاتصال الحي بالعقدة. تعرض هذه الصفحة آخر لقطة قرئت بنجاح.
retry	إعادة الاتصال الآن
langGroup	لغة لوحة التحكم
langFallback	لا توجد بعد قائمة لغوية مدققة، لذا تبقى الصفحة بالإنجليزية (تظل الموجزات والنصوص البرمجية باللغة المختارة)
langSaveHint	تبدلت الصفحة؛ وتحتفظ العقدة بلغتها إلى أن تضغط حفظ
langSaveFailed	تعذر تخزين إعداد اللغة؛ العودة إلى اللغة التي تستخدمها العقدة
railAria	خطوات الإعداد
s1	العتاد والنشر
s2	اقتران iPhone
s3	المحركات والسلطة الفيزيائية
s1Title	الخطوة 1 · مسح العتاد والتثبيت بنقرة واحدة
s1Desc	يقرأ ملف Apple Silicon ويختار حزمة النماذج وفق الذاكرة الموحدة، ويثبت محركات الذكاء الاصطناعي المحلية على هذا Mac.
s2Title	الخطوة 2 · اقتران iPhone
s3Title	الخطوة 3 · عشرة محركات والسلطة الفيزيائية
s3Desc	المفاتيح، ومشاركة الحوسبة الخاملة، والحارس الفيزيائي، وChrono Ark. تكتب العقدة كل تغيير في config/settings.json بشكل صريح.
loading	بانتظار أول لقطة…
loadFailed	تعذر قراءة حالة العقدة
reloadRetry	إعادة المحاولة
noData	لا بيانات بعد
chip	الشريحة
cores	أنوية المعالج
coresNote	أداء P · كفاءة E
mem	الذاكرة الموحدة
memNote	مجمع Apple Silicon المشترك
freeDisk	مساحة SSD الحرة
freeDiskNote	من الإجمالي
tier	فئة الحوسبة
loadTitle	الحمل الحي
loadNote	عينة لحظية
memUsed	الذاكرة المستخدمة
pressure	ضغط الذاكرة
processes	العمليات
cpu	حمل المعالج
nominal	طبيعي
warning	تحذير
critical	حرج
memTitle	مقياس الذاكرة الموحدة
usedOf	مستخدم من
toolchainTitle	فحوص سلسلة الأدوات
toolchainEmpty	لم تبلغ العقدة عن أي فحص لسلسلة الأدوات بعد.
present	موجود
missing	مفقود
stepsTitle	قائمة التجهيز
stepsEmpty	لا توجد عملية نشر بعد. اضغط النشر بنقرة واحدة للبدء.
logTitle	سجل التثبيت الحي
levelFilter	مرشح مستوى السجل
filterAll	كل المستويات
filterInfo	info وما فوق
filterNotice	notice وما فوق
filterWarning	warning وما فوق
filterError	error فقط
copyLog	نسخ السجل
clearLog	مسح
logCleared	تم مسح العرض (سجل العقدة محفوظ)
logLines	أسطر السجل
logLocked	التمرير التلقائي متوقف
logUnlock	استئناف التمرير التلقائي
logEmpty	نافذة السجل فارغة. يبدأ البث فور تشغيل عملية نشر.
logCopied	تم نسخ السجل
deploy	نشر محركات الذكاء الاصطناعي المحلية بنقرة واحدة
cancelInstall	إلغاء النشر
idleHint	يفحص brew / ffmpeg / uv / Ollama، وينزل الأوزان التي تناسب فئة الذاكرة، ويهيئ مساحة عمل LTX-2.5.
installing	النشر قيد التنفيذ
phaseIdle	خامل
phaseDetecting	قيد الكشف
phaseProvisioning	قيد التجهيز
phasePullingLLM	قيد تنزيل النموذج اللغوي
phasePreparingWorkspace	قيد تهيئة مساحة العمل
phaseDownloadingWeights	قيد تنزيل الأوزان
phaseVerifying	قيد التحقق
phaseReady	المحركات جاهزة
phaseFailed	فشل النشر
phaseCancelled	ملغى
deployStarted	تم طلب النشر
deployFailed	تعذر بدء النشر
deployCancel	تم طلب الإلغاء
deployCancelFailed	فشل الإلغاء
installDone	المحركات المحلية جاهزة
installFailedWhy	فشل آخر نشر
planTitle	سلم النماذج الموصى به
planNote	مبرر الخطة
thBand	نطاق الذاكرة
thLLM	النموذج اللغوي
thVideo	دقة الفيديو
thResident	المقيم في الذاكرة
thNote	السياسة
tierCap	محلي بدقة كاملة
tierQuant	محلي مكمم
tierLight	محلي خفيف
heavyLocal	الفيديو الثقيل يعالج محليا
heavyMesh	الفيديو الثقيل يوجه إلى شبكة mesh
noPlan	لم تنتج العقدة خطة نماذج بعد.
modelTitle	إدارة النماذج
modelDefault	افتراضي · حسب فئة الذاكرة
modelResident	الإقامة المقدرة
modelAdmission	قبول الذاكرة
modelGguf	GGUF مخصص
modelCopyPull	نسخ أمر التنزيل
modelSwapWarn	هذا Mac عند حد المبادلة أو دونه: ترفض العقدة المهام المحلية الثقيلة بدل المخاطرة بتعليق النظام بسبب نفاد الذاكرة.
modelSwitched	تم تبديل النموذج المحلي
modelSwitchFailed	تعذر تبديل النموذج المحلي
modelUnpinned	العودة إلى فئة العتاد
modelPinnedNote	مثبت — لم يعد يتبع فئة الذاكرة
modelUnknown	هذا النموذج ليس في الكتالوج، لذا لا تزال أرقام الذاكرة تقديرا خاصا بالفئة.
modelCardTitle	النموذج المحلي والوضع الخفيف
modelMode	الوضع
modelModeLite	خفيف · بلا نماذج
modelModeEnhanced	معزز بالذكاء الاصطناعي · جاهز
modelModeNoModel	معزز بالذكاء الاصطناعي · بانتظار التنزيل
modelPullBtn	تنزيل الآن
modelPulling	قيد التنزيل…
modelCancelBtn	إلغاء التنزيل
modelLiteOn	التبديل إلى الوضع الخفيف
modelLiteOff	الخروج من الوضع الخفيف
modelProgress	تقدم التنزيل
modelReadyLabel	النموذج المحلي جاهز
modelFailed	لم يكتمل التنزيل
modelNone	لا يوجد نموذج لتنزيله
modelPullStarted	بدأ التنزيل
modelPullFailed	فشل طلب التنزيل
modelBoundary	لا يجري التنزيل إلا عبر Ollama المحلي على 127.0.0.1؛ ولا يدخل أي وزن إلى برنامج التثبيت ولا يغادر هذا Mac.
modelFeatureOff	متوقف في الوضع الخفيف
asMailPreset	إعداد مسبق لمزود البريد
asMailPresetNone	إدخال يدوي
asMailPresetHint	اختيار مزود يملأ مضيفي IMAPS/SMTPS ومنافذهما؛ استخدم كلمة مرور خاصة بالتطبيق واحفظها في Keychain على اليمين.
asMailPresetApplied	تم تطبيق القالب
qrTitle	رمز QR للاقتران
qrSub	امسحه من iOS · اكتشف ← اقتران Mac Node. ينهض النفق المشفر على الشبكة نفسها.
qr	رمز QR
qrRetry	إعادة تحميل رمز QR
qrLoading	يتم إنشاء رمز QR…
qrLoadFailed	تعذر تحميل صورة QR
noQR	لا تستطيع العقدة إنشاء صورة QR الآن؛ والارتباط المشفر أدناه صالح ويمكن لصقه يدويا في iOS.
code	رمز اقتران مشفر من طرف إلى طرف
copyCode	نسخ الرمز
uri	معرف URI للدعوة /*PPX_SCHEME*/
copyURI	نسخ URI
pairLink	رابط الاقتران المشفر
copyLink	نسخ الرابط
pairLinkNote	الرابط مختوم بصيغة دعوة المنظومة، لذا لا يسمي أي عقدة إشارة؛ ويحمل رمز QR البايتات نفسها تماما.
pairDiagTitle	بيانات الاقتران الخام (هذا Mac فقط)
pairDiagNote	يحمل الرمز ورابط الدعوة أدناه عنوان طابور SMP، وهما لاستكشاف الأخطاء؛ شارك الرابط المشفر أعلاه.
pairDiagEmpty	لا توجد بيانات اقتران بعد؛ أعد تدوير العرض فتظهر القيم الخام هنا.
pubkey	المفتاح العام للعقدة
expiry	صالح لمدة
expired	انتهت صلاحية رمز الاقتران هذا
used	تم استخدام رمز الاقتران هذا
oneTime	استخدام واحد
rotate	إعادة الإنشاء
rotateFailed	تعذر تدوير عرض الاقتران
noPairing	لم تصدر بوابة الإشارة عرضا بعد. يظهر بمجرد تشغيل الخادم.
tunnel	النفق المشفر مع iPhone قائم
tunnelSub	مفتاح هذا الجهاز مدرج في القائمة البيضاء؛ وهو وحده ما يمكنه تشغيل المحركات العشرة على هذا Mac.
devices	الأجهزة المقترنة
devicesEmpty	لم يكمل أي جهاز مصافحة QR بعد.
revoke	إبطال
revokeDone	أبطل الجهاز
revokeFailed	فشل الإبطال
revokedRow	مبطل
deviceModel	الطراز
pairedAt	وقت الاقتران
lastSeen	آخر ظهور
neverSeen	لم يظهر قط
copyPubkey	نسخ المفتاح
bridgeTitle	جسر إشارة SMP
daemonStopped	الخادم متوقف
daemonStarting	الخادم يبدأ
daemonRunning	الخادم يعمل
daemonDegraded	الخادم متدهور
daemonMissing	ملف popopx-chat التنفيذي مفقود
accepted	مقبول
rejected	مرفوض
delivered	تم التسليم
outbox	عمق صندوق الصادر
uptime	مدة التشغيل
wsOn	WebSocket متصل
wsOff	WebSocket منقطع
daemonPath	مسار الخادم
bridgeErr	آخر خطأ
daemonInstall	popopx-chat غير مثبت —— نزله، ثم تحقق منه، ثم شغله: curl -o- https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh > popopx-install.sh; shasum -a 256 popopx-install.sh (يجب أن تطابق البصمة القيمة الواردة في قسم التثبيت في README — وإن لم تطابق، فلا تشغل السكربت); bash popopx-install.sh يثبت الملف التنفيذي في ~/.local/bin/popopx-chat
enginesTitle	عشرة محركات أعمال
enginesBadge	نشط
enginesLoading	بانتظار أوصاف المحركات…
runs	تشغيلات
failures	إخفاقات
artifacts	مخرجات
lastRun	آخر
busyNow	مشغول
idleNow	خامل
requires	يحتاج
needsModels	يحتاج نماذج محلية
deterministicFlag	حتمي · بلا نموذج
toggleOn	تم التشغيل
toggleOff	تم الإيقاف
toggleFailed	فشل طلب التبديل
save	حفظ الإعدادات
saving	قيد الحفظ…
saved	الإعدادات مطابقة للعقدة
dirty	تعديلات محلية غير محفوظة
saveDone	تمت كتابة الإعدادات
saveFailed	فشل الحفظ
conflict	تحتفظ العقدة بمراجعة أحدث؛ وقد أعيد تحميل النموذج منها
revision	المراجعة
revert	تجاهل
reverted	أعيد إلى مستند العقدة
meshTitle	مشاركة الحوسبة الخاملة
meshOn	المشاركة نشطة
meshOff	المشاركة متوقفة
shareEnable	إعارة الدورات الخاملة
maxMem	أقصى ذاكرة
maxMemHint	سقف آمن على هذا الجهاز
maxJobs	المهام المتزامنة
minFree	أدنى مساحة قرص حرة (GB)
ownerPresent	فقط أثناء وجود المالك
windows	نوافذ الخمول
windowAdd	إضافة نافذة
windowRemove	إزالة
windowEmpty	بلا نافذة لا تقبل العقدة أي عمل أبدا.
from	من
to	إلى
weekdayShort	الأيام
acceptingNow	تقبل الآن
notAcceptingNow	لا تقبل الآن
accrued	النقاط المتراكمة
settled	المهام المحسومة
activeJobs	المهام النشطة
nextWindow	النافذة التالية
meshSandbox	بايتات صندوق العزل
sentinelTitle	حارس الفضاء الفيزيائي
sentinelSub	إغلاق حتمي: لا نموذج في الحلقة، ويطلق فورا عند 🔒 / LOCK_ALL.
sentinelOn	الحارس مسلح
sentinelOff	الحارس متوقف
mounts	الأحجام المراد فصلها
mountAdd	إضافة مسار
mountEmpty	لا مسارات تحميل مهيأة؛ سيقتصر الإغلاق على مسح الحافظة وقفل الشاشة واستدعاء webhook.
mountHint	مثال: /Volumes/ENCRYPTED أو smb://… (يفصل عبر diskutil وقت القفل)
clipboard	مسح الحافظة عند القفل
lockScreen	قفل الشاشة
sleepDisplays	إسبات الشاشات
phrases	عبارات التشغيل (مفصولة بفواصل)
hookUrl	رابط Home Assistant / webhook
hookSecret	سر توقيع webhook
secretShow	إظهار
secretHide	إخفاء
drill	تشغيل التدريب الآن
drillDone	عاد إيصال التدريب
drillFailed	فشل التدريب
drillPending	التدريب قيد التنفيذ…
drillTitle	إيصالات الإغلاق الحتمي
receiptEmpty	لا إغلاق مسجل بعد. اضغط تشغيل التدريب الآن لإنتاج واحد.
modelFree	بلا نموذج
modelUsed	نموذج مشارك (غير متوقع)
receiptTrigger	سبب التشغيل
receiptClip	الحافظة
receiptUnmount	تم الفصل
receiptMountFail	إخفاقات الفصل
receiptScreen	الشاشة
receiptWebhook	Webhook
receiptElapsed	المدة المستغرقة
arkTitle	Chrono Ark
arkSub	قفل زمني تشفيري مع رعاية النبضات الفائتة؛ يفتح في موعده أو بعد الصمت.
arkOk	الوصي سليم
arkAlert	تأخر النبض
beat	فترة النبض (ساعات)
missed	النبضات الفائتة المسموح بها
graceDue	موعد الإفراج
lockDur	القفل الزمني (بالثواني)
lockDays	نحو
daysUnit	يوما
unlocks	أقرب فتح
directory	مجلد الأرشيف المشفر
dirHint	تحدده العقدة عند vault/sealed/، وهو بالضبط حيث يكتب chrono_ark كبسولاته
dirReveal	إظهار في Finder
dirUnsupported	لا يمكن لصفحة سرد المجلدات المحلية أو تغيير هذا المسار؛ وتنفذ العقدة «إظهار في Finder» على هذا الجهاز.
revealFailed	تعذر على العقدة فتح مجلد الأرشيف
archives	الأرشيفات المختومة
archivesEmpty	لم يختم شيء بعد.
archiveSealedAt	ختم
archiveOpens	يفتح
archiveRounds	جولات
archiveFingerprint	بصمة المفتاح
archiveOpen	تجاوز القفل
archiveSealed	لا يزال مختوما
beneficiary	اسم المستفيد
beneficiaryQueue	طابور المستفيدين
devTitle	درج المطور
devHint	لقطة JSON خام وحقن أوامر الشبكة
devOpen	توسيع
devClose	طي
rawFetch	جلب اللقطة الخام
rawCopy	نسخ JSON
rawEmpty	لم تجلب بعد.
rawFailed	فشل الجلب
rawTruncated	مقتطعة للعرض
cmdLabel	حقن أمر ::popopx_sys::NODE_CMD
cmdHint	الصيغة ::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}؛ ويسلك المسار نفسه الذي يسلكه أمر iOS بالضبط.
cmdSend	تنفيذ
cmdClear	مسح الناتج
cmdEmpty	اكتب أمرا أولا
cmdDone	تم تنفيذ الأمر
cmdFailed	فشل الأمر
copyDone	تم النسخ إلى الحافظة
copyFailed	فشل النسخ
loopbackNote	الصفحة وAPI تأتيان من 127.0.0.1 فقط؛ لا سكربتات خارجية ولا خطوط ولا متتبعات.
unknown	غير معروف
yes	نعم
no	لا
never	أبدا
secondsUnit	ث
ago	مضت
paired	مقترن
released	أفرج عنه
now	الآن
s4	جسور الخصوصية
s4Title	جسور الخصوصية والتأكيد اليدوي
s4Desc	تقرأ بيانات التقويم ومساحة العمل الخام على هذا Mac فقط؛ وما يعرض هنا هو خلاصة العقدة نفسها والإجراءات التي تنتظرك.
pvGuarantee	كل ما في هذه الصفحة يأتي من لقطة loopback: تهمل عناوين الأحداث ومواقعها وحاضروها ونصوص الملفات قبل ترميزها، وكل كتابة تحتاج تأكيدا ثانيا هنا أو على هاتف مقترن.
pvAccessTitle	مفاتيح التفويض
pvAuthNote	المفتاح هو منح العقدة نفسها؛ وقد يرفض macOS الوصول إلى التقويم بشكل منفصل، لذا تظهر حالة النظام أدناه.
pvCalSwitch	قراءة فترات انشغال التقويم (لا محتوى الأحداث)
pvReadSwitch	تلخيص الملفات داخل المجلدات المصرح بها
pvWriteSwitch	الكتابة داخل المجلدات المصرح بها (بتأكيد لكل عملية)
pvNotifySwitch	إشباري في مركز الإشعارات عند وصول اقتراح
pvAskAccess	طلب وصول التقويم من macOS
pvAuthAgain	اسأل macOS مجددا
pvAuthAsked	تم تحديث حالة التفويض من macOS
pvAuthAskFailed	فشل طلب الوصول
pvCheck	فحص ذاتي للأيام السبعة القادمة
pvCheckOff	جسر التقويم متوقف، لذا لا يرسل أي استعلام
pvCheckFree	تم العثور على فترات حرة
pvCheckNone	لا فترة حرة داخل هذه النافذة
pvCheckFailed	تم رفض الفحص الذاتي
pvDirsTitle	المجلدات المصرح بها
pvDirAdd	إضافة مجلد
pvDirRemove	إزالة
pvDirHint	اكتبها على نمط المستخدم، مثل ~/Documents/Projects. وتحتفظ العقدة بالأولى ثلاثا وتقرأ داخلها فقط.
pvDirEmpty	لا مجلد بعد؛ التلخيص والكتابة مرفوضان كلاهما.
pvDirMax	بلغ عدد المجلدات سقفه، أزل واحدا أولا
pvDirOpen	موجود ويمكن الوصول إليه
pvDirClosed	مفقود أو يتعذر الوصول إليه
pvDirsKnown	المجلدات التي تقبلها العقدة فعلا وتحلها
pvDirsKnownNote	هذا العمود جواب العقدة لا حقول الإدخال: لا يتطابق إلا بعد الحفظ، وسقوط مدخل منه يعني تجاوز السقف.
pvDirNoneSaved	لم تقبل العقدة أي مجلد
pvRulesTitle	قواعد الفترات الحرة وافتراضات الاقتراح
pvWorkStart	بداية العمل
pvWorkEnd	نهاية العمل
pvDuration	المدة الافتراضية (دقيقة)
pvBuffer	هامش حولها (دقيقة)
pvLunchStart	بداية الغداء
pvLunchEnd	نهاية الغداء
pvBlockLunch	عد الغداء مشغولا
pvWorkdays	أيام العمل
pvZone	المنطقة الزمنية
pvZoneNote	الحقل الفارغ يعني المنطقة الزمنية الحالية لهذا Mac.
pvCallTemplate	قالب رابط المكالمة
pvCallNote	يستبدل {ref} و{node} بالقيم الفعلية؛ والفراغ يعني أن الاقتراحات لا تحمل رابطا.
pvPropTitle	اقتراحات تنتظرك
pvBookTitle	حجوزات أنشأتها هذه العقدة
pvAuditTitle	سجل التدقيق المحلي
pvAuditCopy	نسخ السجل
pvNone	لا شيء ينتظر قرارا
pvNoBookings	لم تكتب هذه العقدة حدث تقويم بعد
pvNoAudit	لا مدخلات بعد
pvStatPending	بالانتظار
pvStatBookings	الحجوزات
pvStatDirs	مجلدات متاحة
pvStatDirsNote	متاح / السقف
pvBadgePending	بانتظارك
pvBadgeQuiet	لا شيء لك
pvActCreate	إنشاء حدث
pvActReschedule	إعادة جدولة
pvActCancel	إلغاء حدث
pvActWrite	كتابة ملف
pvActOrganize	تنظيم ملفات
pvActInvoke	استدعاء أداة
pvStatePending	بانتظارك
pvStateApproved	معتمد
pvStateExecuted	تم التنفيذ
pvStateRejected	مرفوض
pvStateExpired	منتهي الصلاحية
pvStateFailed	فشل التنفيذ
pvStateCancelled	ملغى
pvDomainCal	التقويم
pvDomainWs	مساحة العمل
pvDomainMCP	MCP
pvDomainHome	المنزل
pvApprove	موافقة وتنفيذ
pvReject	رفض
pvConfirmAgain	انقر مرة أخرى للتأكيد
pvCannotApprove	لا يمكن تنفيذ هذا الإجراء: المفتاح أو المجلد الذي يحتاجه غير نشط
pvTtlOver	انتهت المهلة
decisionDone	تم تطبيق قرارك
decisionFailed	تعذر تطبيق القرار
s5	جسور المركز الطرفي
s5Title	الاكتشاف المحلي وجسور البروتوكولات
s5Desc	لا تفحص العقدة إلا هذا Mac والعناوين الخاصة التي تسردها. تبدأ كل قدرة متوقفة، وحتى النشطة منها تمر بالبوابة نفسها للتأكيد الثاني.
hvGuarantee	كل شيء هنا يقدم من عنوان loopback: لا خروج للشبكة، ولا مسح منافذ، ولا مضيف تخميني. وترفض العقدة أي هدف عام قبل إنشاء أي مقبس، وتدرج العدد والسبب.
hvDiscTitle	اكتشاف القدرات المحلية
hvDiscIdle	لم يجر أي قياس بعد
hvScan	فحص الآن
hvScanning	قيد القياس
hvScanFailed	فشل الفحص
hvBoundary	العنوان المحلي (loopback) إضافة إلى أهداف الشبكة المحلية التي سردها المالك
hvKindEngine	محرك
hvKindModel	نموذج
hvKindWorkspace	مساحة عمل
hvKindCalendar	تقويم
hvKindLan	شبكة محلية
hvKindRefused	مرفوض
hvStatePresent	موجود
hvStateAbsent	غائب
hvStateInstalled	مثبت
hvStateAuthorized	مصرح به
hvStateDenied	مرفوض من macOS
hvStateOff	متوقف
hvStateReachable	متاح
hvStateSilent	صامت
hvStateRefused	مرفوض
hvStateFull	مصرح به
hvStateWrite	كتابة فقط
hvStateRestricted	مقيد
hvStateNotAsked	لم يطلب بعد
hvStateNoBridge	غير مرتبط
hvStatCaps	القدرات
hvStatRefused	الأهداف المرفوضة
hvStatRefusedNote	لم تحاول العقدة أي اتصال
hvStatServers	خوادم MCP
hvStatServersNote	مسجل / متصل
hvStatEntities	الكيانات المرئية
hvStatEntitiesNote	من قائمة السماح
hvBadgePending	بانتظارك
hvBadgeOn	الجسور نشطة
hvBadgeOff	الكل متوقف
hvPropTitle	إجراءات الجسور التي تنتظرك
hvPropNone	لا إجراء جسر ينتظر قرارا
hvSwitchTitle	مفاتيح الجسور (كلها متوقفة افتراضيا)
hvSwitchNote	لا يسري المفتاح إلا إذا كان خلفه شيء: بلا خادم MCP مسجل، ولا عنوان Home Assistant أو وسيط، ولا خادم CalDAV، تقرأه العقدة متوقفا.
hvMcpSwitch	تمكين عميل MCP المحلي (stdio أو HTTP عبر loopback)
hvHomeSwitch	تمكين Home Assistant وMQTT (الشبكة الخاصة فقط)
hvCalDavSwitch	تمكين CalDAV للفترات الحرة/المشغولة (نوافذ فقط، لا محتوى الأحداث أبدا)
hvAutoScan	فحص القدرات المحلية عند فتح لوحة التحكم
hvReadonly	المنزل الذكي للقراءة فقط: انعكاس الحالة، دون تشغيل فعلي
hvTelemetry	قبول قياسات MQTT (يتطلب عوامل تصفية للموضوعات)
hvStatusTitle	حالة الجسور
hvStatusIdle	لم يستعلم بعد
hvChecking	قيد السؤال
hvRefresh	اسأل مجددا
hvGateNote	الأسطر الثلاثة كلها تأتي من نقاط إدخال الأدوات نفسها التي يستخدمها هاتف مقترن: تنفذ العقدة نداءات القراءة فقط، وكل ما يغير الحالة يصبح اقتراحا وتكتبه العقدة في سجل التدقيق المحلي.
hvBridgeMCP	عميل MCP
hvBridgeHome	Home Assistant · MQTT
hvBridgeCalDav	CalDAV للفترات الحرة/المشغولة
hvHaOk	Home Assistant مهيأ
hvHaAbsent	Home Assistant غير موجود
hvMqttOk	الوسيط متصل
hvMqttAbsent	الوسيط غير متصل
hvRejectedEntries	مدخلات السجل المرفوضة
hvHaUrl	رابط Home Assistant
hvHaNote	loopback و10/8 و172.16/12 و192.168/16 و.local فقط؛ وترفض العقدة أي عنوان عام أو نطاق خارجي قبل إنشاء أي مقبس.
hvHaToken	رمز وصول طويل الأمد (Keychain)
hvMqttHost	مضيف MQTT
hvMqttHostPlaceholder	مثال: 192.168.1.20
hvMqttNote	الحدود نفسها للشبكة الخاصة؛ وتتحدث العقدة MQTT v3.1.1 بنفسها، دون طرف ثالث في الوسط.
hvMqttPassword	كلمة مرور MQTT (Keychain)
hvSecretSave	حفظ في Keychain
hvSecretStored	بيانات الاعتماد مخزنة مشفرة
hvMqttPort	منفذ MQTT
hvSecretFailed	لم تخزن بيانات الاعتماد
hvSecretEmpty	اكتب بيانات الاعتماد أولا
hvServerRequired	حدد خادم CalDAV أولا
hvCalDavId	معرف خادم CalDAV
hvCalDavIdNote	يجب أن يطابق خادما مدرجا بالفعل في مستند الإعدادات.
hvCalDavPassword	كلمة مرور CalDAV أو رمز التطبيق
hvCalDavPasswordNote	مرجع فقط مرة أخرى: لا تضع العقدة القيمة في ملف الإعدادات ولا في سطر سجل ولا في أي رد تقرأه هذه الصفحة.
hvEntitiesTitle	قائمة الكيانات المسموح بها
hvEntityAdd	إضافة كيان
hvEntityNote	الكيان غير المدرج هنا لا وجود له عند هذه العقدة. والأقفال وأجهزة الإنذار والصفارات والكاميرات والمكنسات تحتاج التأكيد الثاني حتى لو كانت مدرجة.
hvEntityEmpty	قائمة السماح فارغة، لذا يظهر الجسر متوقفا
hvEntityLimit	بلغت قائمة السماح سقفها
hvTargetsTitle	أهداف فحص الشبكة المحلية (اختياري)
hvTargetAdd	إضافة هدف
hvTargetNote	المضيف والمنفذ. محاولة TCP واحدة بمهلة 350 ms؛ وترفض العقدة أي عنوان عام وتحسبه ضمن الأهداف المرفوضة أعلاه.
hvTargetEmpty	لا هدف مدرج، لذا تفحص العقدة هذا Mac فقط
hvTargetLimit	بلغت قائمة الفحص سقفها
upTitle	التحديثات ذات التوقيع
upDesc	بيان HTTPS واحد يثبته المالك هو المصدر الوحيد للجلب؛ وتتجاهل العقدة أي توقيع سيئ أو إصدار غير أحدث دون بطاقة.
upCheck	التحقق من التحديثات
upChecking	قيد التحقق
upCheckFailed	فشل التحقق
upFound	يتوفر إصدار جديد
upUpToDate	لديك أحدث إصدار
upIgnored	تم التجاهل بهدوء
upFailed	فشل إجراء التحديث
upDone	تم
upBadgeReady	بانتظارك
upBadgeOn	التحديثات نشطة
upBadgeIncomplete	غير مكتمل
upBadgeOff	التحديثات متوقفة
upCurrent	الإصدار الحالي
upKey	مفتاح البيان
upLastCheck	آخر تحقق
upInstalled	مثبت
upPendingTitle	جاهز للتثبيت
upNoPending	لا إصدار ينتظر قرارا
upBuild	البناء
upReleased	صدر
upPackage	الحزمة
upSummary	ما الجديد
upApprove	تحديث الآن
upSnooze	ذكرني لاحقا
upConfirmAgain	انقر مرة أخرى للتأكيد
upRefused	مرفوض
upConfigTitle	مصدر التحديث (يهيئه المالك)
upSwitchNote	أنت توفر البيان والمفتاح معا؛ ولا تجلب العقدة مفتاحا من مضيف البيان ولا تتبع أي إعادة توجيه.
upEnabled	تمكين فحوص التحديث ذات التوقيع
upManifestURL	رابط البيان
upManifestNote	يجب أن يكون https على المنفذ 443 وبالمضيف الذي كتبته بالضبط؛ وترفض العقدة كل إعادة توجيه.
upPublicKey	المفتاح العام Ed25519 (base64url)
upKeyNote	مفتاح من 32 بايتا؛ وتظهر بصمته في الإحصاءات أعلاه ولا يستخدم التحقق سوى هذه القيمة.
upPackageHosts	مضيفات الحزم المسموح بها (مفصولة بفواصل)
upPackageNote	مضيف البيان مسموح دائما؛ أدرج فقط المضيفات الإضافية التي قد يشير إليها بيان ذو توقيع، مثل CDN.
upInterval	فترة الفحص (دقائق)
upSnoozeHours	مدة التأجيل (ساعات)
upGateNote	الكشف تلقائي، أما التثبيت فليس كذلك: لا ينزل شيء قبل أن تضغط تحديث الآن، وتفحص العقدة الحزمة المنزلة من حيث الحجم وSHA-256 قبل أن يفتحها macOS.
dcFeedTitle	أحدث العناصر
dcEmpty	لا عناصر بعد؛ اضغط تحديث
dcRefresh	تحديث الآن
dcRefreshing	قيد التحديث
dcRefreshFailed	فشل التحديث
dcRefreshNote	تحمل البطاقة فهرسا قابلا للقراءة؛ والحمولة المذيلة بالتوقيع هي feed.json، وتسلمها العقدة في الجلسة المشفرة نفسها وتكتبها في سجل التدقيق المحلي.
dcConfigTitle	إعدادات مجمع المحتوى
dcSwitchNote	متوقف افتراضيا؛ وحتى بعد تشغيله يظهر متوقفا إلى أن يوجد مجلد أو تغذية أو مصدر MCP.
dcEnabled	تمكين مجمع Discover
dcBadgeOn	مجمع المحتوى نشط
dcBadgeOff	مجمع المحتوى متوقف
dcInterval	فترة التحديث (دقائق)
dcMaxItems	أقصى عدد عناصر في الدورة
dcFoldersTitle	المجلدات المحلية (نص فقط)
dcFolderAdd	إضافة مجلد
dcFolderNote	تقرأ العقدة ملفات النص العادي فقط داخل مجلد المستخدم الرئيسي؛ وتتجاوز الروابط الرمزية والملفات المفرطة الحجم والمجلدات المتداخلة بعمق زائد.
dcFolderEmpty	لم يضف مجلد
dcFolderLimit	بلغت قائمة المجلدات سقفها
dcFeedsTitle	تغذيات RSS / JSON (الشبكة الخاصة فقط)
dcFeedAdd	إضافة تغذية
dcFeedOn	نشط
dcFeedNote	ترفض العقدة العنوان العام بواسطة EdgeBoundary قبل إنشاء أي مقبس، ويظهر ذلك في حالة المصدر أدناه.
dcFeedEmpty	لم تضف تغذية
dcFeedLimit	بلغت قائمة التغذيات سقفها
dcMcpTitle	مصادر MCP للقراءة فقط
dcMcpAdd	إضافة مصدر MCP
dcMcpNote	أدوات القراءة فقط؛ ولا يشغل مجمع المحتوى أداة تغير الحالة أبدا.
dcMcpEmpty	لم يضف مصدر MCP
dcMcpLimit	بلغت قائمة MCP سقفها
dcSourcesTitle	حالة المصادر
dcSourcesIdle	لم يجر تشغيل بعد
dcSourcesNote	تكتب العقدة كل دورة في سجل التدقيق المحلي؛ ولا يزال التسليم يستخدم الجلسة المقترنة من طرف إلى طرف.
dcStatItems	العناصر
dcStatSources	المصادر
dcStatLastRun	آخر تشغيل
dcStatDelivered	آخر تسليم
dcKindFolder	مجلد
dcKindRSS	RSS / Atom
dcKindJSON	تغذية JSON
dcKindMCP	MCP
dcStateOk	سليم
dcStateRefused	مرفوض
geTitle	خريطة الذكاء العالمية (God's Eye View)
geDesc	برنامج طرف ثالث منفصل تثبته وتشغله على هذا Mac؛ ولا تتحقق هذه العقدة إلا من إصدار مثبت، وتطلقه على 127.0.0.1، وتسجل مدخل MCP المتحقق منه كأداة تبدأ بالقراءة.
geStart	تشغيل
geStop	إيقاف
geHealth	فحص
geBadgeRunning	يعمل
geBadgeOn	نشط
geBadgeOff	متوقف
geStatNode	Node.js
geStatInstall	التثبيت
geStatPort	منفذ loopback
geStatHealth	السلامة
geRunning	يعمل
geStopped	متوقف
geAbsent	غائب
geUnverified	غير متحقق منه
geNoPath	غير مرتبط
geStatePath	مجلد التثبيت
geStateMode	الوضع
geStateProcess	العملية المحلية
geStateVerified	آخر تحقق
geStateError	آخر خطأ
geModeExisting	ربط تثبيت قائم
geModePinned	استنساخ إصدار مثبت
geMode	وضع التثبيت
geModeNote	يستنسخ الوضع المثبت التزاما واحدا بعد نقرة ويتطلب مفتاح التنزيل من الشبكة.
geMcpTitle	أدوات MCP
geMcpRegister	إعادة التسجيل
geMcpSync	مزامنة الأدوات
geMcpUnregister	إلغاء التسجيل
geMcpRegistered	مسجل
geMcpOff	غير مسجل
geToolsIdle	تظهر الأدوات هنا بعد التشغيل والمزامنة
geToolRead	قراءة فقط
geToolWrite	كتابة · موافقة
geConfigTitle	البرنامج والمنفذ (يهيئهما المالك)
geSwitch	تمكين God's Eye View
geSwitchNote	متوقف افتراضيا. احفظ المفتاح والمسارات أولا، ثم اضغط تشغيل؛ ولا تشغله هذه العقدة عند الإقلاع.
gePath	مجلد التثبيت
gePathPlaceholder	~/Tools/gods-eye-view
gePathNote	مسار مطلق أو يبدأ بـ ~؛ وترفض العقدة مجلدات النظام وKeychain وبيانات العقدة.
geVersion	الإصدار المثبت
geVersionNote	يجب أن يعلن package.json هذا الإصدار بالضبط وإلا رفضت العقدة التشغيل.
gePort	منفذ loopback
gePortNote	مرتبط بـ 127.0.0.1 فقط؛ وترفض العقدة أي منفذ مشغول.
geNodePath	ملف Node.js التنفيذي
geNodePlaceholder	الفراغ يعني الكشف التلقائي
geNodeNote	يتطلب Node.js 20 أو أحدث؛ والفراغ يستخدم node من PATH.
gePull	السماح باستنساخ مثبت لمرة واحدة
gePullNote	متوقف افتراضيا؛ والنقرة على تثبيت وحدها هي التي تطلب، ويجب أن يساوي HEAD التزام 40-hex.
geRepo	مستودع المصدر (https)
geRepoNote	بلا بيانات اعتماد ولا استعلام ولا جزء.
geRef	الوسم أو الفرع المثبت
geRefNote	يستخدم مع الالتزام؛ والوسم المتحرك لا يغير ما يعمل.
geCommit	الالتزام المثبت (40 hex)
geCommitNote	يجب أن يساويه HEAD للنسخة المستنسخة بالضبط.
geVerify	التحقق من التثبيت
geInstall	تثبيت / تحقق
geInstallNote	وضع التثبيت القائم يتحقق فقط؛ والوضع المثبت يستنسخ إلى مجلد مؤقت ولا يستبدل الهدف إلا بعد نجاح التحقق.
geCredTitle	تغذيات اختيارية (macOS Keychain)
geCredNote	تذهب القيم إلى Keychain فقط؛ وتحتفظ الإعدادات بمراجع تصبح متغيرات بيئة عند الإطلاق ولا تظهر أبدا في الصفحة أو سجل التدقيق أو أي لقطة.
geCredStore	حفظ في Keychain
geCredMissing	غير مخزنة
geSourceOn	تمرر إلى البرنامج المحلي عند الإطلاق
geCredEmpty	بيانات الاعتماد فارغة
geCredStored	خزنت في Keychain
geCredFailed	لم تخزن بيانات الاعتماد
geActionFailed	فشل الإجراء
geActionDone	مقبول
geSaveFirst	احفظ الإعدادات قبل التشغيل
dcStateFailed	فشل
dcStateOff	متوقف
dcLabel	التسمية
dcUrl	URL
dcKindField	النوع
dcServer	معرف الخادم
dcTool	الأداة
dcArgs	وسائط JSON
hvRemove	إزالة
asTitle	المساعد الخاص
asDesc	أذونات موحدة للموصلات وجداول زمنية محلية. كل كتابة تحتاج موافقة المالك على بطاقة في الهاتف أو في لوحة التحكم هذه، وتتحقق طبقة التنفيذ من الإيصال المذيل بالتوقيع.
asBadgeOn	نشط
asBadgeOff	متوقف
asBadgePending	قيد الانتظار
asStatPending	قيد الانتظار
asStatPendingNote	لا شيء ينفذ قبل الموافقة
asStatDrafts	المسودات
asStatDraftsNote	يبقى النص على هذا Mac
asStatConnectors	الموصلات النشطة
asStatConnectorsNote	قراءة أو اقتراح فقط
asStatMail	البريد
asMailReady	بيانات الاعتماد مخزنة
asMailMissing	بيانات الاعتماد مفقودة
asSwitchesTitle	الجداول المحلية
asSwitchNote	متوقف افتراضيا؛ احفظ ثم مكن. ويبقى الاختيار بعد إعادة التشغيل.
asMaster	المفتاح الرئيسي للمساعد
asBriefingSwitch	موجز خاص يومي
asPatrolSwitch	دورية أجهزة المنزل
asMailSwitch	فرز بريد للقراءة فقط
asBriefHour	ساعة الموجز
asBriefHourNote	التوقيت المحلي، 0–23
asBriefMinute	دقيقة الموجز
asBriefMinuteNote	0–59
asPatrolInterval	فترة الدورية (دقائق)
asPatrolIntervalNote	5–1440 دقيقة
asPatrolOffline	حد انقطاع الاتصال (دقائق)
asPatrolOfflineNote	لا تقدم العقدة اقتراحا إلا بعد هذه المدة
asImapHost	مضيف IMAP
asImapHostNote	TLS ضمني فقط، المنفذ 993؛ بلا اكتشاف
asImapPort	منفذ IMAP
asSmtpHost	مضيف SMTP
asSmtpHostNote	TLS ضمني فقط، المنفذ 465؛ بلا فحص
asSmtpPort	منفذ SMTP
asPortNote	لا يستخدم سوى 993 و465
asMailUser	حساب البريد
asMailUserNote	للتسجيل فقط، ولا تسجله العقدة أبدا
asMailFrom	عنوان المرسل
asMailFromNote	حقل المرسل في مسودات الرد
asLookback	أيام الرجوع
asLookbackNote	1–14 يوما
asMaxMessages	الرسائل في الدورة
asMaxMessagesNote	1–30 رسالة
asBriefingNow	موجز الآن
asPatrolNow	دورية الآن
asMailNow	فرز البريد الآن
asSaveFirst	احفظ المساعد ومكنه أولا
asRunDone	تم
asRunFailed	فشل التشغيل
asConnectorsTitle	أذونات الموصلات
asConnectorsIdle	لم تجمع بعد
asConnectorsNote	القراءة تجمع، والاقتراح يصوغ مسودات؛ والكتابة تحتاج إيصالا ذا توقيع أولا.
asPermRead	قراءة
asPermPropose	اقتراح
asPermWrite	كتابة
asPermAdmin	إدارة
asKindCalendar	تقويم
asKindCalDav	CalDAV
asKindSmartHome	منزل ذكي
asKindMcp	MCP
asKindGodsEye	God's Eye View
asKindMail	بريد
asKindOther	أخرى
asMailCredsTitle	بيانات اعتماد البريد (مراجع Keychain)
asCredImap	كلمة مرور IMAP
asCredSmtp	كلمة مرور SMTP
asCredPlaceholder	كلمة مرور خاصة بالتطبيق
asCredStore	حفظ في Keychain
asCredStored	مخزنة
asCredMissing	مفقودة
asCredEmpty	أدخل كلمة المرور
asCredFailed	لم تخزن بيانات الاعتماد
asCredNote	تذهب القيمة إلى Keychain في macOS فقط؛ وتتضمن اللقطات وسجل التدقيق المرجع. احفظ المساعد ومكنه أولا.
asPendingTitle	الموافقات المعلقة
asPendingIdle	لا شيء بالانتظار
asTtl	المتبقي
asCancelAll	إلغاء كل المعلق
asPendingNote	تحمل البطاقات الهدف والخلاصة؛ ويصدر الإيصال على بطاقة الهاتف أو داخل هذه العقدة.
asAuditTitle	التدقيق المحلي (SQLite)
asAuditIdle	لا مدخلات بعد
asDecisionDone	تم التطبيق
asDecisionFailed	لم يطبق
asRepairsTitle	الأجهزة الحرجة وإجراءات الإصلاح
asRepairOn	نشط
asRepairsEmpty	لا جهاز حرج مسجل
asRepairsFull	بلغ الحد
asRepairAdd	إضافة قاعدة
asRepairsNote	الدورية للقراءة فقط؛ وتنفذ العقدة الإصلاح مرة واحدة، وبعد الموافقة فقط.
asInklingTitle	Inkling 2 Mini (محلي)
asInklingDesc	استدلال متعدد الوسائط ومنظم بصيغة JSON على الجهاز عبر 127.0.0.1 فقط. لا ترفق الأوزان ببرنامج التثبيت أبدا، وتبقى الصور على هذا Mac.
asInklingOff	متوقف
asInklingUnknown	لم يفحص
asInklingReady	جاهز
asInklingModelMissing	النموذج لم ينزل
asInklingRuntimeMissing	لا بيئة تشغيل محلية
asInklingRefused	نقطة النهاية مرفوضة
asInklingProbe	فحص بيئات التشغيل المحلية
asInklingEnable	تمكين Inkling 2 Mini المحلي
asInklingMultimodal	قراءة التذاكر متعددة الوسائط
asInklingJSON	استدلال JSON منظم
asInklingOllama	نقطة نهاية Ollama
asInklingMlx	نقطة نهاية MLX
asInklingEndpointNote	127.0.0.1 أو localhost أو [::1] فقط؛ وأي شيء آخر ترفضه العقدة دون أي طلب
asInklingModel	مرجع النموذج
asInklingModelNote	اسم النموذج داخل Ollama، مثل inkling-2-mini
asInklingTickets	مسارات التذاكر (مفصولة بفواصل)
asInklingTicketsNote	حتى 4، وكل مسار داخل مجلد مصرح به في مساحة العمل
asInklingRuntime	بيئة التشغيل
asInklingStats	JSON / وسائط / متدهور
asInklingLastUsed	آخر استخدام
asInklingNever	أبدا
asInklingPull	تنزيل محلي: 
asInklingNote	لا يقرأ النموذج ويقترح إلا؛ أما الإرسال أو كتابة التقويم أو التحكم بالمنزل فما زالت تحتاج إيصالا معتمدا من إنسان.
opTitle	العمليات والذاكرة المحلية
opDesc	الطبيب والاسترجاع العرضي ومذكرات الصوت ومراقب النظام. يبقى كل شيء على 127.0.0.1 وعلى الحسابات المهيأة بالفعل؛ ولا تزال الكتابات تحتاج إيصالا معتمدا من إنسان.
opDoctorRun	تشغيل فحص الحزمة الكامل
opDoctorNever	لم يجر تشغيل بعد
opDoctorIdle	استخدم الزر أعلاه؛ الناتج منقح ولا تقرأ العقدة أي نص رسالة.
opDoctorOk	سليم
opDoctorWarning	تحذير
opDoctorFailed	فشل
opDoctorSkipped	متجاوز
opHistoryTitle	الذاكرة العرضية المحلية (FTS5 مختومة)
opHistoryAsk	اسأل عن الماضي، مثلا: ما آخر فاتورة؟
opHistoryRun	اسأل السجل
opHistoryIndex	فهرسة مساحة العمل
opHistoryNote	العناوين والنصوص والمصادر مختومة بـ AES-GCM؛ ولا يرى فهرس النص الكامل إلا بصمات رموز HMAC. ولا تغادر أي بايتات هذا Mac.
opHistoryEmpty	لا مدخلات مفهرسة بعد؛ افهرس مساحة عمل أو شغل موجزا أولا.
opHistoryNoAnswer	لم يعثر على شيء ذي صلة
opQueryEmpty	أدخل سؤالا
opIndexDone	اكتملت الفهرسة
opVoiceTitle	مذكرات صوتية (على الجهاز)
opVoiceIdle	لا مذكرات صوتية بعد. ويصبح الصوت الوارد من الهاتف موافقات معلقة أولا.
opVoiceNote	التعرف على الكلام على الجهاز من Apple أو whisper.cpp على 127.0.0.1؛ ويبقى النص في الذاكرة حتى تكتبه موافقة.
opWatchTitle	مراقب النظام والتشغيل عند تسجيل الدخول
opWatchInstall	التشغيل عند تسجيل الدخول
opWatchUninstall	إزالة التشغيل عند تسجيل الدخول
opWatchCheck	فحص الآن
opWatchRefresh	تحديث الحالة
opWatchIdle	لا فحوص مسجلة بعد
opWatchNote	يستخدم LaunchAgent وسائط argv ثابتة عبر loopback؛ وتعاد التشغيلات غير المتوقعة بتباعد أسي متزايد، وتزال التكرارات في التنبيهات خلال 30 دقيقة وترسل إلى الهاتف.
opWatchInstalled	مثبت
opWatchAbsent	غير مثبت
"""#
}

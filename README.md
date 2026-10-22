# Sensor Panel para Windows

> **Projeto em desenvolvimento. A leitura dos sensores depende dos aplicativos de monitoramento e da configuração do computador. A interface e as leituras ainda precisam de validação manual nesta publicação.**

**[Baixar Sensor Panel — pacote 0.1.0 Beta](https://github.com/sugyua/sensor-panel/releases/tag/v0.1.0-beta)** — scripts PowerShell para um painel de monitoramento no Windows, com uma versão original e uma versão personalizada para monitor secundário de 1280 × 400. A versão identifica o primeiro pacote de distribuição, sem novas funções dos scripts.

Consulte as [instruções da versão personalizada](MinhaVersao/LEIA-ME.txt). As dependências externas devem ser instaladas separadamente. O download é um arquivo dos fontes e do executável preexistente; não é um instalador.

## Arquitetura

Os scripts usam Windows Forms e System.Drawing para desenhar o painel. Classes C# compiladas em memória por `Add-Type` consultam as áreas de memória compartilhada das ferramentas de monitoramento. As duas versões são independentes.

| Arquivo ou diretório | Finalidade |
| --- | --- |
| `SensorPanel.ps1` | Versão original; consulta HWiNFO, RTSS e informações do Windows; solicita execução como administrador |
| `SensorPanel.exe` | Executável preexistente, preservado sem alterações; processo de compilação não disponível nesta pasta |
| `MinhaVersao/Painel.ps1` | Painel personalizado para exatamente um monitor secundário de 1280 × 400; inclui leitura do MSI Afterburner |
| `MinhaVersao/AbrirPainel.vbs` | Inicializador do painel personalizado sem janela de console |
| `MinhaVersao/LEIA-ME.txt` | Instruções e comportamento da versão personalizada |

Logs locais ficam fora do repositório por meio do `.gitignore`. O executável preexistente não teve sua correspondência com os fontes comprovada nesta preparação.

## Recursos presentes no código

- Temperatura, uso e outras leituras de CPU e GPU, conforme as fontes disponíveis.
- Uso de memória RAM e VRAM.
- FPS e tempo por quadro quando há captura de um aplicativo pelo RTSS.
- Na versão personalizada, velocidades de download e upload em Mb/s e histórico de FPS dos últimos 30 segundos.
- Atualização da versão personalizada a cada segundo e saída pela tecla **Esc**.
- Temperaturas em vermelho a partir de 72 °C na versão personalizada; o aviso visual não controla ventoinhas.

A presença no código não equivale a validação completa no hardware. A versão personalizada só abre se encontrar exatamente um monitor **não principal** de 1280 × 400. Sem esse monitor, registra o motivo em `MinhaVersao/Painel.log` e encerra. Os títulos de CPU e GPU dessa interface estão definidos no código como Ryzen 5 5600X e AMD RX 7800 XT.

## Novidades desta publicação

- Organização dos arquivos existentes em um repositório próprio.
- README no padrão de documentação do projeto [Destinia](https://github.com/sugyua/destinia).
- Exclusão de logs locais do controle de versão.

Os scripts e o executável existentes foram preservados. Esta publicação não atribui uma nova versão funcional ao programa.

## Dependências

As dependências externas devem ser instaladas separadamente no PC do usuário.

| Dependência | Quando é necessária |
| --- | --- |
| Windows com ambiente gráfico e Windows PowerShell 5.1 | Execução dos scripts com Windows Forms, System.Drawing e `Add-Type` |
| Windows Script Host | Inicialização por `AbrirPainel.vbs`, quando permitida pela configuração do Windows |
| MSI Afterburner com sensores ativos na aba Monitoring | Fonte de leituras da versão personalizada |
| RivaTuner Statistics Server (RTSS) | FPS e dados de quadros do jogo ou aplicativo capturado |
| HWiNFO com memória compartilhada disponível | Fonte de sensores usada pelo código original e consultada pela versão personalizada |
| Exatamente um monitor secundário de 1280 × 400 | Abertura da versão personalizada |

Sem captura de jogo, FPS e frametime podem ficar indisponíveis. Sem uma fonte de sensores ativa, os campos podem mostrar valores indisponíveis. O frametime da versão personalizada pode ser estimado a partir do FPS quando não há leitura direta.

## Abrir com duplo clique

Extraia o ZIP para uma pasta gravável. Inicie as ferramentas de monitoramento e habilite os sensores. Na pasta `MinhaVersao`, abra **AbrirPainel.vbs**. Pressione **Esc** para fechar. Se não abrir, consulte `MinhaVersao/Painel.log` e confirme a resolução e o papel secundário do monitor.

Para executar o fonte original, abra o Windows PowerShell na pasta do projeto e execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SensorPanel.ps1
```

O script original solicita elevação de privilégios. A opção `ExecutionPolicy Bypass` vale para o processo iniciado; ela não altera permanentemente a política do computador. Não há receita de compilação do EXE nesta pasta.

## Desenvolvimento e distribuição

Os fontes PowerShell estão disponíveis para inspeção. Preserve os arquivos da versão personalizada juntos para que o inicializador encontre `Painel.ps1`. Não distribua `Painel.log`, pois ele contém diagnóstico da execução local.

A preparação do repositório inclui análise sintática dos dois scripts pelo parser do PowerShell. Esse procedimento não executa a interface nem comprova leituras de sensores, permissões ou compatibilidade com versões específicas das ferramentas externas.

## Melhorias concluídas com sucesso

- [x] Documentação de arquitetura, dependências e inicialização.
- [x] Diferenciação entre a versão original e a versão personalizada.
- [x] Exclusão de logs locais da publicação.

## Atualizações futuras

Não foi definido um cronograma de novas funções. A integração ao Xiri Launcher usa `xiri.json` e o pacote ZIP Windows com `SHA256SUMS.txt` publicado na release. A entrada é `MinhaVersao/Painel.ps1`, que continua exigindo o monitor e as ferramentas indicados acima. A integração completa depende de uma versão validada do Xiri Launcher.

## Publicação

Publicação dos arquivos existentes solicitada pelo autor em 22/10/2026. A inspeção estática não substitui a validação manual da interface e dos sensores no Windows. O executável original não foi iniciado nem recompilado nesta etapa.

Não foi definida uma licença para o código deste projeto nesta publicação. MSI Afterburner, RTSS e HWiNFO são ferramentas externas e não estão incluídos no repositório.

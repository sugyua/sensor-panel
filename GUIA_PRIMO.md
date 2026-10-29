# Guia Rápido de Instalação e Uso — Sensor Panel (Versão de Teste)

Olá! Este é o pacote de teste do **Sensor Panel** (versão **0.2.0 Beta**), compilado nativamente em C#/.NET para se adaptar automaticamente às peças do seu PC e à resolução do seu monitor.

---

## 1. Como abrir o programa
1. **Extraia todo o conteúdo do arquivo `.zip`** para uma pasta fixa no seu computador (por exemplo: `C:\Meus Programas\SensorPanel` ou na sua Área de Trabalho).
   * *Importante:* Não abra o programa de dentro do `.zip` sem extrair antes.
2. Abra a pasta extraída e dê **duplo clique em `SensorPanel.exe`**.
3. O painel vai detectar automaticamente o modelo do seu **Processador (CPU)**, da sua **Placa de Vídeo (GPU)**, sua **Memória RAM** e a velocidade de **Download/Upload da sua internet**.
4. Você pode **redimensionar a janela livremente** pelas bordas (ou maximizar). Para fechar, clique no **X** da janela ou aperte a tecla **ESC**.

---

## 2. Como ativar as leituras completas (Temperaturas da GPU/CPU e FPS em Jogos)
Sem nenhum programa extra instalado, o **Sensor Panel** já mostra o uso da CPU, clock, uso de RAM e velocidade de rede (via Windows/WMI), exibindo `N/A` nos sensores que dependem de driver externo.

Se você quiser ver também a **Temperatura da Placa de Vídeo/CPU, VRAM usada e o gráfico de FPS em tempo real nos jogos**, basta abrir **um** dos dois programas abaixo (se você já usar no seu PC):
* **Opção A — MSI Afterburner + RivaTuner (RTSS):** basta deixar o MSI Afterburner aberto em segundo plano.
* **Opção B — HWiNFO64:** abra o HWiNFO64 na janela **Sensors** com a opção **Shared Memory Support** ativada nas configurações.

---

## 3. O que fazer se o antivírus Avast mostrar um aviso (Tela Azul de "Arquivo Raro" / CyberCapture)

Como este executável (`SensorPanel.exe`) acabou de ser compilado por nós e não possui um certificado comercial pago da Microsoft (que custa caro anualmente), o **Avast** pode exibir uma janela dizendo *"Espere um pouco, este arquivo é raro"* (CyberCapture) ou sugerir bloqueio preventivo.

Se isso acontecer, siga este passo a passo simples para colocar a pasta nas **Exceções do Avast**:

1. Abra o **Avast Antivirus** no seu computador.
2. No canto superior direito, clique em **Menu** (ícone de três traços `☰`) e depois em **Configurações**.
3. Na aba **Geral** (à esquerda), clique em **Exceções**.
4. Clique no botão **Adicionar exceção**.
5. Clique em **Procurar**, selecione a pasta onde você extraiu o `SensorPanel` (ex: `C:\Meus Programas\SensorPanel`) e clique em **OK**.
6. Clique em **Adicionar exceção** para confirmar.

*(Dica extra: se o Avast tiver movido o `SensorPanel.exe` para a Quarentena no primeiro clique, vá em **Proteção** → **Quarentena**, clique nos três pontinhos `...` ao lado do `SensorPanel.exe` e escolha **Restaurar e adicionar exceção**).*

---

## 4. Verificação de Integridade (SHA-256)
Para ter certeza de que o arquivo `SensorPanel.exe` é exatamente o original que enviamos:
* **Arquivo:** `SensorPanel.exe`
* **Tamanho:** `38.400 bytes` (37,5 KB)
* **SHA-256:** `5762D7BD21E2F847B4BCA990177CC97A8C2B90EBE221C392AC90117E221A06C8`

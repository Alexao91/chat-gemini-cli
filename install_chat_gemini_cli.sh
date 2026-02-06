#!/bin/bash
set -e

# --- KONFIGURATION ---
USER_NAME="aiuser"
HOME_DIR="/home/$USER_NAME"
APP_DIR="$HOME_DIR/app"
WEBUI_DIR="$HOME_DIR/openwebui"
WORKSPACE_DIR="$HOME_DIR/workspace"

# Farben
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== Starte Ultimate Gemini LXC Setup (SSH & Homebrew) ===${NC}"

# 1. System & SSH (als Root)
echo -e "${GREEN}[1/7] Installiere Systemabhängigkeiten & SSH...${NC}"
apt-get update && apt-get upgrade -y
# Dependencies + SSH Server
apt-get install -y build-essential procps curl file git python3 python3-venv python3-pip sudo acl openssh-server

# SSH aktivieren und starten
systemctl enable ssh
systemctl start ssh

# 2. User 'aiuser' erstellen
if ! id "$USER_NAME" &>/dev/null; then
    echo -e "${GREEN}[2/7] Erstelle User '$USER_NAME'...${NC}"
    useradd -m -s /bin/bash "$USER_NAME"
    # User zu sudo hinzufügen (optional, aber nützlich für Maintenance)
    usermod -aG sudo "$USER_NAME"
    echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/aiuser
else
    echo "User $USER_NAME existiert bereits."
fi

# 3. Homebrew Installation (als aiuser)
echo -e "${GREEN}[3/7] Installiere Homebrew & Node...${NC}"

sudo -u "$USER_NAME" bash <<EOF
set -e
export NONINTERACTIVE=1

# Homebrew installieren (falls nicht da)
if [ ! -d "/home/linuxbrew/.linuxbrew" ]; then
    /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Umgebungsvariablen in .bashrc schreiben
if ! grep -q "eval \"\$(\/home\/linuxbrew\/.linuxbrew\/bin\/brew shellenv)\"" $HOME_DIR/.bashrc; then
    echo 'eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> $HOME_DIR/.bashrc
fi

# Für die aktuelle Session aktivieren
eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# Node und Gemini CLI installieren
echo "Installiere Node und Gemini-CLI via Brew..."
brew install node
brew install gemini-cli

# Config Ordner vorbereiten (für deinen manuellen Token)
mkdir -p $HOME_DIR/.config/gemini-cli
# Oder je nach Version auch .gemini, wir erstellen beides zur Sicherheit
mkdir -p $HOME_DIR/.gemini

EOF

# 4. Verzeichnisse erstellen
echo -e "${GREEN}[4/7] Erstelle Verzeichnisstruktur...${NC}"
sudo -u "$USER_NAME" mkdir -p "$APP_DIR" "$WEBUI_DIR" "$WORKSPACE_DIR"
chmod 777 "$WORKSPACE_DIR"

# 5. Python API Bridge erstellen
echo -e "${GREEN}[5/7] Erstelle Python Middleware...${NC}"

sudo -u "$USER_NAME" bash << 'EOF'
cd ~/app
python3 -m venv venv
source venv/bin/activate
pip install fastapi uvicorn pydantic python-multipart uvicorn[standard]

# Wir erstellen den Python Wrapper Code
cat << 'PY_END' > main.py
import subprocess
import os
import time
import threading
import select
from contextlib import asynccontextmanager
from typing import List
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# --- CONFIG ---
WORKSPACE_DIR = os.path.expanduser("~/workspace")
FILE_PORT = 8090
GEMINI_BIN = "/home/linuxbrew/.linuxbrew/bin/gemini"

# --- WRAPPER CLASS ---
class GeminiWrapper:
    def __init__(self):
        self.process = None
        self.lock = threading.Lock()

    def start(self):
        if self.process and self.process.poll() is None:
            return 
        
        env = os.environ.copy()
        env["TERM"] = "xterm"
        # Pfade sicherstellen
        env["PATH"] = f"/home/linuxbrew/.linuxbrew/bin:{env.get('PATH', '')}"
        
        # Startet 'gemini chat'
        try:
            self.process = subprocess.Popen(
                [GEMINI_BIN, "chat"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=0, 
                env=env
            )
            # Kurz warten für Init
            time.sleep(2)
            # Anfangs-Output (Welcome Msg) lesen und verwerfen
            self._read_until_silence()
        except FileNotFoundError:
            print("CRITICAL: gemini binary not found. Homebrew path correct?")

    def stop(self):
        if self.process:
            self.process.terminate()
            self.process = None

    def restart(self):
        self.stop()
        time.sleep(1)
        self.start()

    def _read_until_silence(self, timeout=15.0):
        """Liest stdout bis Stille herrscht"""
        output = []
        silence_threshold = 0.5 
        last_data_time = time.time()
        
        while True:
            if self.process and self.process.poll() is not None:
                break
            
            reads = [self.process.stdout.fileno()]
            ret = select.select(reads, [], [], 0.1)

            if ret[0]:
                char = self.process.stdout.read(1)
                if char:
                    output.append(char)
                    last_data_time = time.time()
            else:
                if time.time() - last_data_time > silence_threshold and len(output) > 0:
                    break
                if time.time() - last_data_time > timeout and len(output) == 0:
                     break
        return "".join(output)

    def send_message(self, message: str):
        with self.lock:
            if not self.process or self.process.poll() is not None:
                self.start()
            
            # Nachricht senden
            try:
                self.process.stdin.write(message + "\n")
                self.process.stdin.flush()
                return self._parse_files(self._read_until_silence())
            except Exception as e:
                return f"Error communicating with CLI process: {e}"

    def _parse_files(self, text):
        """Sucht nach ### filename: block"""
        lines = text.split('\n')
        current_file = None
        file_content = []
        clean_text = []

        for line in lines:
            if "### filename:" in line:
                current_file = line.split("### filename:")[1].strip()
                file_content = []
                clean_text.append(line) 
            elif current_file and "```" in line:
                if file_content: 
                    self._write_file(current_file, "\n".join(file_content))
                    current_file = None
                clean_text.append(line)
            elif current_file:
                file_content.append(line)
                clean_text.append(line)
            else:
                clean_text.append(line)
        return "\n".join(clean_text)

    def _write_file(self, filename, content):
        path = os.path.join(WORKSPACE_DIR, os.path.basename(filename))
        try:
            with open(path, "w") as f:
                f.write(content)
        except Exception as e:
            print(f"Error writing file: {e}")

gemini = GeminiWrapper()

# --- FASTAPI ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    fs = subprocess.Popen(["python3", "-m", "http.server", str(FILE_PORT), "--directory", WORKSPACE_DIR])
    try:
        gemini.start()
    except Exception as e:
        print(f"Start Error: {e}")
    yield
    fs.terminate()
    gemini.stop()

app = FastAPI(lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class ChatReq(BaseModel):
    messages: List[dict]
    model: str

@app.post("/v1/chat/completions")
async def chat(req: ChatReq):
    last_msg = next((m["content"] for m in reversed(req.messages) if m["role"] == "user"), None)
    if not last_msg: raise HTTPException(400, "No user message")
    
    resp_text = gemini.send_message(last_msg)
    
    return {
        "id": "chatcmpl-gemini",
        "object": "chat.completion",
        "created": int(time.time()),
        "choices": [{"index": 0, "message": {"role": "assistant", "content": resp_text}, "finish_reason": "stop"}]
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
PY_END
EOF

# 6. Open WebUI installieren
echo -e "${GREEN}[6/7] Installiere Open WebUI...${NC}"
sudo -u "$USER_NAME" bash << 'EOF'
cd ~/openwebui
python3 -m venv venv
source venv/bin/activate
pip install open-webui
EOF

# 7. Systemd Services
echo -e "${GREEN}[7/7] Konfiguriere Services...${NC}"

# Backend Service
cat << EOF > /etc/systemd/system/gemini-bridge.service
[Unit]
Description=Gemini Homebrew Bridge
After=network.target

[Service]
User=$USER_NAME
WorkingDirectory=$APP_DIR
Environment="PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$APP_DIR/venv/bin/python main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Frontend Service
cat << EOF > /etc/systemd/system/open-webui.service
[Unit]
Description=Open WebUI
After=gemini-bridge.service

[Service]
User=$USER_NAME
WorkingDirectory=$WEBUI_DIR
Environment="PORT=8080"
Environment="OPENAI_API_BASE_URL=[http://127.0.0.1:8000/v1](http://127.0.0.1:8000/v1)"
Environment="OPENAI_API_KEY=dummy"
Environment="WEBUI_AUTH=False"
Environment="PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$WEBUI_DIR/venv/bin/open-webui serve
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gemini-bridge
systemctl enable open-webui

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}Installation fertig! Aber noch EINE Aufgabe:${NC}"
echo -e "${BLUE}======================================================${NC}"
echo -e "1. Setze ein Passwort für den User 'aiuser', damit SSH funktioniert:"
echo -e "   ${GREEN}passwd aiuser${NC}"
echo -e ""
echo -e "2. Kopiere deine Gemini Config Datei von deinem PC auf diesen Container:"
echo -e "   Die Datei gehört nach: ${GREEN}/home/$USER_NAME/.config/gemini-cli/config.json${NC}"
echo -e "   (Manchmal auch config.yaml, einfach prüfen was du lokal hast)"
echo -e ""
echo -e "   Befehl vom PC aus (Beispiel):"
echo -e "   ${BLUE}scp ~/.config/gemini-cli/config.json aiuser@<LXC-IP>:~/.config/gemini-cli/${NC}"
echo -e ""
echo -e "3. Starte danach die Services:"
echo -e "   ${GREEN}systemctl start gemini-bridge && systemctl start open-webui${NC}"
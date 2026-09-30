JARVIS + Ollama setup

For a physical Android phone, Ollama must accept connections from the local network.

1. On the Windows PC running Ollama, run START_OLLAMA_FOR_JARVIS.bat.
2. If Windows asks for Administrator permission, allow the firewall rule.
3. Find the PC's LAN IPv4 address with `ipconfig`.
4. In JARVIS, open Profile -> AI and set Ollama server to:
   http://YOUR-PC-LAN-IP:11434
5. Keep the phone and PC on the same Wi-Fi network.
6. Make sure the selected model exists on the PC, for example:
   ollama pull llama3.2:3b

The JARVIS app checks /api/tags before sending a chat request, so network failures are reported quickly instead of waiting 60 seconds.

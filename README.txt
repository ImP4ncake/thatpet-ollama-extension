ThatPet Ollama Extension
========================

WHAT IT DOES
  Makes ThatPet react to Ollama Desktop replies: Thinking while the model
  writes, working at the laptop while it uses a tool (e.g. web search), Done
  when it finishes, the error animation if Ollama fails, and back to idle if
  you stop a reply. It never reads or stores your chat text.
  It starts by itself at every macOS login, together with ThatPet.

THE MENU BAR ICON (top right, next to ThatPet's cat)
  Two designs, chosen in the menu under Icon Style:
    ThatPet | Ollama   ThatPet's cat and Ollama's llama peeking over the same
                       edge, then a "+" (the two apps, connected)
    ThatPet +          ThatPet's cat with a "+" beside it
  The cat is identical to ThatPet's own and at the same height; both icons
  are read from the two apps without modifying them. Full icon = on;
  dimmed = off.
  It always sits right to the left of ThatPet's icon. To move them, hold Cmd
  and drag ThatPet's cat where you want it: macOS remembers the spot and the
  extension follows it within a few seconds.

  Click it to open the menu:
    switch               turn the extension on or off (off = stays off after
                         a restart until you turn it back on)
    ThatPet              Open / Not open
    Last reaction        the last animation sent to the pet, with the time
    orange warning       only when something is wrong, e.g. "Reply end not
                         detected" after an Ollama update: then check the log
    Open Ollama
    Show Log             the extension's log
    Open Project Folder  this folder
    Icon Style           ThatPet | Ollama or ThatPet +
    Quit Extension (Cmd+Q)  stops the extension until the next login

  After Quit Extension, double-click "ThatPet Ollama Extension.app" in this folder to
  bring the icon back before the next login.

WHERE EVERYTHING IS
  This folder (Documents > Ollama ThatPet Bridge) is the master copy:
    ollama_thatpet_bridge.py        the bridge
    autostart.py                    install, turn on/off, quit, remove
    ThatPet Ollama Extension.app    the menu bar icon
    menubar/                        the icon's source code (Swift)
    build_menu_app.sh               rebuilds the icon after a code change
    test-logs/                      logs from the tests of 2026-10-19

  The copies that run automatically (bridge and icon) live here, because
  macOS does not let background programs read the Documents folder:
    ~/Library/Application Support/OllamaThatPetBridge/
  Autostart:  ~/Library/LaunchAgents/local.ollama-thatpet-bridge.plist
              ~/Library/LaunchAgents/local.ollama-thatpet-bridge.menu.plist
  Log:        ~/Library/Logs/ollama-thatpet-bridge.log
  The Library folder is hidden in Finder: use Go > Go to Folder...
  (Shift+Cmd+G) and paste the path.
  Don't delete these files by hand: use "uninstall" (below).

COMMANDS (in Terminal)
  cd ~/Documents/"Ollama ThatPet Bridge"
  python3 autostart.py status      status and the last log lines
  python3 autostart.py stop        turn off (like the switch)
  python3 autostart.py start       turn on (like the switch)
  python3 autostart.py quit        stop until the next login (like Quit)
  python3 autostart.py install     after a change: update the copies in use
  python3 autostart.py uninstall   remove autostart, icon and copies (the log stays)

VERSIONS
  This folder is a git repository, so every change is saved:
    git log --oneline                    list of saved versions
    git checkout <version> -- <file>     bring back an old version of a file
  After changing the bridge or the icon: ./build_menu_app.sh (icon only),
  then python3 autostart.py install.

GOOD TO KNOW
  - ThatPet must never receive SessionEnd: it makes it quit (verified).
  - Only one bridge runs at a time: one started by hand while autostart is on
    refuses to start (the autostart one waits instead), so ThatPet never gets
    events twice.
  - The log is cut back to its last 200 KB when it passes 1 MB.
  - Ollama errors right after a web search ("No user query found in
    messages") are not caused by the extension. Web results are large (20-115
    KB of text) and Ollama's default context here is 4096 tokens, so Ollama
    cuts the start of the chat, including your question. The model
    frob/qwen3.5-instruct:9b then crashes (its built-in template requires the
    question), while the official qwen3.5:9b keeps working. Fix: in Ollama's
    Settings raise the context length (16k or more), and/or use qwen3.5:9b
    (thinking is already off). Verified on 2026-10-20 with Ollama 0.40.6.

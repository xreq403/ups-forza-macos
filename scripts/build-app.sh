#!/usr/bin/env bash
# Compila la app con Xcode y deja "build/UPSForza.app".
#   scripts/build-app.sh            compila (Release)
#   scripts/build-app.sh --install  además la copia a /Applications y la abre
# Firma con el certificado Apple Development del equipo configurado en el proyecto
# (hace falta para el daemon root). Otro equipo: DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ARGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    SIGN_ARGS=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development")
fi

xcodebuild -project UPSForza.xcodeproj -scheme UPSForza -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build/DerivedData -quiet build ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}

APP="build/UPSForza.app"
rm -rf "$APP"
cp -R build/DerivedData/Build/Products/Release/UPSForza.app "$APP"

# Que macOS no registre la copia intermedia de DerivedData: con varias copias del
# mismo bundle id, Notificaciones puede tomar una vieja (p. ej. sin ícono).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister_build_copies() {
    for p in build/DerivedData/Build/Products/*/UPSForza.app "$APP"; do
        [[ -d "$p" ]] && "$LSREGISTER" -u "$PWD/$p" 2>/dev/null || true
    done
}
unregister_build_copies
echo "OK: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x UPSForza 2>/dev/null || true
    rm -rf "/Applications/UPSForza.app" "/Applications/UPS Forza.app"
    cp -R "$APP" /Applications/
    open "/Applications/UPSForza.app"
    sleep 2
    unregister_build_copies   # que solo quede registrada la copia instalada
    echo "Instalada en /Applications"
fi

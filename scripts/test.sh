#!/usr/bin/env bash
# Pruebas de integración de la API contra el despliegue real (curl + node para leer JSON).
# Uso:  scripts/test.sh
# Lee API_URL y API_KEY de .env.local (o del entorno). Todo lo que crea lo borra al final.
set -u
cd "$(dirname "$0")/.."
if [ -f .env.local ]; then set -a; . ./.env.local; set +a; fi
: "${API_URL:?Falta API_URL (ej: https://REF.supabase.co/functions/v1/api). Ponela en .env.local}"
: "${API_KEY:?Falta API_KEY. Ponela en .env.local}"
API_URL="${API_URL%/}"

TMP="$(mktemp -d)"
PASS=0; FAIL=0; STATUS=""; BODY=""
IDS=(); REGLAS=()
GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'

# req MÉTODO RUTA [JSON] [KEY]   → deja STATUS y BODY. KEY="__none__" no manda el header.
req() {
  local method="$1" path="$2" data="${3-}" key="${4-$API_KEY}"
  local args=(-sS -o "$TMP/body" -w '%{http_code}' -X "$method" "$API_URL$path")
  [ "$key" != "__none__" ] && args+=(-H "x-api-key: $key")
  [ -n "$data" ] && args+=(-H 'content-type: application/json' --data-binary "$data")
  STATUS="$(curl "${args[@]}" 2>"$TMP/err")" || STATUS="000($(cat "$TMP/err"))"
  BODY="$(cat "$TMP/body" 2>/dev/null)"
}
# jx 'expresión JS sobre d'  ← lee JSON por stdin (d = el JSON parseado)
# Sin regex literales /…/ en las expresiones: Git Bash (Windows) los toma por rutas y reescribe el argumento.
jx() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const d=JSON.parse(s);const r=eval(process.argv[1]);console.log(r===undefined||r===null?"":typeof r==="object"?JSON.stringify(r):r)}catch(e){console.log("ERR")}})' "$1"
}
check() { # nombre esperado obtenido
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GREEN" "$OFF" "$1"
  else FAIL=$((FAIL+1)); printf '  %sFAIL%s %s %s(esperado: %s | obtenido: %s)%s\n' "$RED" "$OFF" "$1" "$DIM" "$2" "$3" "$OFF"; [ -n "$BODY" ] && printf '       %s%s%s\n' "$DIM" "${BODY:0:300}" "$OFF"; fi
}
seccion() { printf '\n%s\n' "== $1 =="; }

# crear MÉTODO RUTA JSON → registra el id para limpiar; deja el id en $ID
crear() {
  req POST "$1" "$2"
  ID="$(printf '%s' "$BODY" | jx 'd.id')"
  [ -n "$ID" ] && [ "$ID" != "ERR" ] && IDS+=("$ID")
}
limpiar() {
  for id in "${IDS[@]:-}"; do [ -n "$id" ] && curl -s -o /dev/null -X DELETE -H "x-api-key: $API_KEY" "$API_URL/gastos/$id"; done
  for id in "${REGLAS[@]:-}"; do [ -n "$id" ] && curl -s -o /dev/null -X DELETE -H "x-api-key: $API_KEY" "$API_URL/reglas/$id"; done
  rm -rf "$TMP"
}
trap limpiar EXIT

HOY="$(node -e "console.log(new Date().toLocaleDateString('en-CA',{timeZone:'America/Asuncion'}))")"
MES="${HOY:0:7}"
DIAS_MES="$(node -e "const [y,m]='$MES'.split('-').map(Number);console.log(new Date(Date.UTC(y,m,0)).getUTCDate())")"
resumen() { req GET "/resumen?mes=$MES$1"; }

seccion "Autenticación y CORS"
req GET /meta "" __none__;            check "sin x-api-key → 401" 401 "$STATUS"
req GET /meta "" clave-incorrecta;    check "key incorrecta → 401" 401 "$STATUS"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS -H 'Origin: https://ejemplo.github.io' -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: x-api-key' "$API_URL/meta")"
check "preflight CORS (OPTIONS sin key) → 200" 200 "$CODE"
HDR="$(curl -s -D - -o /dev/null -H "x-api-key: $API_KEY" "$API_URL/meta" | tr -d '\r' | grep -i '^access-control-allow-origin' | head -1 | tr 'A-Z' 'a-z')"
check "respuestas llevan Access-Control-Allow-Origin" "access-control-allow-origin: *" "$HDR"

seccion "Meta"
req GET /meta;                                            check "GET /meta → 200" 200 "$STATUS"
check "incluye la categoría Otros" true "$(printf '%s' "$BODY" | jx 'd.categorias.some(c=>c.nombre==="Otros")')"
check "incluye la cuenta Efectivo" true "$(printf '%s' "$BODY" | jx 'd.cuentas.includes("Efectivo")')"
check "cada categoría trae emoji y color" true "$(printf '%s' "$BODY" | jx 'd.categorias.every(c=>c.emoji&&c.color.startsWith("#"))')"

seccion "Estado inicial ($MES)"
resumen "";                    check "GET /resumen → 200" 200 "$STATUS"
TOTAL0="$(printf '%s' "$BODY" | jx 'd.total')"; CANT0="$(printf '%s' "$BODY" | jx 'd.cantidad')"
check "diario trae un día por cada día del mes ($DIAS_MES)" "$DIAS_MES" "$(printf '%s' "$BODY" | jx 'd.diario.length')"
resumen "&cuenta=Tarjeta";     TARJ0="$(printf '%s' "$BODY" | jx 'd.total')"
req GET "/resumen?mes=$MES&tipo=ingreso"; ING0="$(printf '%s' "$BODY" | jx 'd.total')"

seccion "POST /gastos — registro rápido y datos sucios de Atajos"
crear /gastos '{"monto":150000,"categoria":"Comida","descripcion":"__test__ numero"}'
check "monto numérico → 201" 201 "$STATUS"; ID_A="$ID"
check "respuesta ok:true"  true "$(printf '%s' "$BODY" | jx 'd.ok')"
check "texto para la notificación (monto · categoría)" true "$(printf '%s' "$BODY" | jx 'd.texto.includes("150.000")&&d.texto.includes("Comida")')"
echo "  ${DIM}texto: $(printf '%s' "$BODY" | jx 'd.texto')${OFF}"
crear /gastos '{"monto":"150.000","categoria":"Comida","descripcion":"__test__ texto"}';       ID_B="$ID"; check "monto \"150.000\" → 201" 201 "$STATUS"
crear /gastos '{"monto":"Gs. 150.000","categoria":"Comida","descripcion":"__test__ gs"}';      ID_C="$ID"; check "monto \"Gs. 150.000\" → 201" 201 "$STATUS"
crear /gastos '{"monto":"₲150.000","categoria":"Comida","descripcion":"__test__ simbolo"}';    ID_D="$ID"; check "monto \"₲150.000\" → 201" 201 "$STATUS"
crear /gastos '{"monto":"12,50","categoria":"Comida","descripcion":"__test__ decimal"}';       ID_E="$ID"; check "monto \"12,50\" → 201" 201 "$STATUS"
crear /gastos '{"monto":3000,"categoria":"🍔 Comida","descripcion":""}';                       ID_F="$ID"; check "categoría \"🍔 Comida\" → 201" 201 "$STATUS"
crear /gastos '{"monto":4000,"categoria":"categoria-que-no-existe","descripcion":"__test__ otros"}'; ID_G="$ID"; check "categoría inexistente → 201" 201 "$STATUS"
crear /gastos '{"monto":5000,"tipo":"ingreso","categoria":"Otros","descripcion":"__test__ ingreso","cuenta":"Transferencia"}'; ID_H="$ID"; check "ingreso → 201" 201 "$STATUS"

seccion "POST /gastos — validaciones"
req POST /gastos '{"monto":"abc","categoria":"Comida"}';   check "monto \"abc\" → 400" 400 "$STATUS"
req POST /gastos '{"monto":0,"categoria":"Comida"}';       check "monto 0 → 400" 400 "$STATUS"
req POST /gastos '{"categoria":"Comida"}';                 check "sin monto → 400" 400 "$STATUS"
req POST /gastos '{"monto":100,"cuenta":"NoExiste"}';      check "cuenta inexistente → 400" 400 "$STATUS"
req POST /gastos 'esto no es json';                        check "body inválido → 400" 400 "$STATUS"

seccion "POST /wallet — autocategorización"
req POST /reglas '{"patron":"zz-test-comercio","categoria":"🛒 Supermercado"}'
check "POST /reglas → 201" 201 "$STATUS"; REGLAS+=("$(printf '%s' "$BODY" | jx 'd.regla.id')")
check "regla guardada en minúsculas y con la categoría limpia" "zz-test-comercio|Supermercado" "$(printf '%s' "$BODY" | jx 'd.regla.patron+"|"+d.regla.categoria')"
crear /wallet '{"monto":"Gs. 45.000","comercio":"ZZ-TEST-COMERCIO SUC 9","tarjeta":"Visa 1234"}'; ID_J="$ID"
check "wallet con regla → 201" 201 "$STATUS"
check "texto muestra la categoría resuelta" true "$(printf '%s' "$BODY" | jx 'd.texto.includes("Supermercado")')"
crear /wallet '{"monto":1000,"comercio":"COMERCIO SIN REGLA ZZ"}'; ID_K="$ID"
check "wallet sin regla → 201" 201 "$STATUS"
req POST /wallet '{"monto":"nada","comercio":"x"}';        check "wallet con monto inválido → 400" 400 "$STATUS"
req GET /reglas;                                           check "GET /reglas → 200" 200 "$STATUS"
check "la regla de prueba aparece en la lista" true "$(printf '%s' "$BODY" | jx 'd.some(r=>r.patron==="zz-test-comercio")')"

seccion "GET /gastos — lista y filtros"
req GET "/gastos?desde=$HOY&hasta=$HOY";                   check "GET /gastos por día → 200" 200 "$STATUS"
LISTA="$BODY"
g() { printf '%s' "$LISTA" | jx "(d.find(x=>x.id==='$1')||{}).$2"; }
check "A: 150000 guardado como 150000" 150000 "$(g "$ID_A" monto)"
check "B: \"150.000\" → 150000" 150000 "$(g "$ID_B" monto)"
check "C: \"Gs. 150.000\" → 150000" 150000 "$(g "$ID_C" monto)"
check "D: \"₲150.000\" → 150000" 150000 "$(g "$ID_D" monto)"
check "E: \"12,50\" → 12.5" 12.5 "$(g "$ID_E" monto)"
check "F: \"🍔 Comida\" → Comida" Comida "$(g "$ID_F" categoria)"
check "F: descripción vacía → null" "" "$(g "$ID_F" descripcion)"
check "G: categoría inexistente → Otros" Otros "$(g "$ID_G" categoria)"
check "H: tipo ingreso" ingreso "$(g "$ID_H" tipo)"
check "H: cuenta Transferencia" Transferencia "$(g "$ID_H" cuenta)"
check "J: wallet → Supermercado" Supermercado "$(g "$ID_J" categoria)"
check "J: wallet → cuenta Tarjeta, fuente wallet" "Tarjeta|wallet" "$(g "$ID_J" cuenta)|$(g "$ID_J" fuente)"
check "K: wallet sin regla → Otros" Otros "$(g "$ID_K" categoria)"
check "la lista viene ordenada de más nuevo a más viejo" true "$(printf '%s' "$LISTA" | jx 'd.every((x,i)=>i===0||d[i-1].fecha>=x.fecha)')"
req GET "/gastos?desde=$HOY&hasta=$HOY&tipo=ingreso"
check "filtro tipo=ingreso incluye H y ningún gasto" "true|true" "$(printf '%s' "$BODY" | jx "d.some(x=>x.id==='$ID_H')+'|'+d.every(x=>x.tipo==='ingreso')")"
req GET "/gastos?desde=$HOY&hasta=$HOY&cuenta=Tarjeta"
check "filtro cuenta=Tarjeta solo trae Tarjeta" true "$(printf '%s' "$BODY" | jx "d.length>=2&&d.every(x=>x.cuenta==='Tarjeta')")"
req GET "/gastos?desde=ayer";                              check "fecha inválida → 400" 400 "$STATUS"

seccion "GET /resumen — totales de un solo golpe"
resumen ""
TOTAL1="$(printf '%s' "$BODY" | jx 'd.total')"; CANT1="$(printf '%s' "$BODY" | jx 'd.cantidad')"
check "total sube 653012.5 (solo gastos, sin el ingreso)" 653012.5 "$(node -e "console.log(Math.round(($TOTAL1-$TOTAL0)*100)/100)")"
check "cantidad sube 9" 9 "$((CANT1-CANT0))"
check "por_categoria incluye Comida con emoji" true "$(printf '%s' "$BODY" | jx 'd.por_categoria.some(c=>c.categoria==="Comida"&&c.emoji&&c.color)')"
check "el día de hoy figura en diario con total > 0" true "$(printf '%s' "$BODY" | jx "(d.diario.find(x=>x.dia==='$HOY')||{total:0}).total>0")"
check "trae total_prev numérico" true "$(printf '%s' "$BODY" | jx 'typeof d.total_prev==="number"')"
resumen "&cuenta=Tarjeta"
check "filtro cuenta=Tarjeta suma solo J+K (+46000)" 46000 "$(node -e "console.log(Math.round(($(printf '%s' "$BODY" | jx 'd.total')-$TARJ0)*100)/100)")"
req GET "/resumen?mes=$MES&tipo=ingreso"
check "tipo=ingreso sube 5000" 5000 "$(node -e "console.log($(printf '%s' "$BODY" | jx 'd.total')-$ING0)")"
req GET "/resumen?mes=2026-13";                            check "mes inválido → 400" 400 "$STATUS"
req GET "/resumen";                                        check "sin parámetros usa el mes actual → 200" 200 "$STATUS"
check "…y devuelve el mes actual" "$MES" "$(printf '%s' "$BODY" | jx 'd.mes')"

seccion "PATCH /gastos/:id — recategorizar"
req PATCH "/gastos/$ID_K" '{"categoria":"🍔 Comida"}';    check "PATCH categoría → 200" 200 "$STATUS"
check "categoría actualizada" Comida "$(printf '%s' "$BODY" | jx 'd.gasto.categoria')"
req PATCH "/gastos/$ID_K" '{"categoria":"Nada"}';         check "PATCH con categoría inexistente → 400" 400 "$STATUS"
req PATCH "/gastos/$ID_K" '{}';                            check "PATCH sin campos → 400" 400 "$STATUS"
req PATCH "/gastos/00000000-0000-0000-0000-000000000000" '{"categoria":"Comida"}'; check "PATCH de un id que no existe → 404" 404 "$STATUS"

seccion "DELETE — limpieza y verificación"
for id in "${IDS[@]}"; do
  req DELETE "/gastos/$id"
  [ "$STATUS" = "200" ] || check "DELETE /gastos/$id → 200" 200 "$STATUS"
done
check "se borraron los ${#IDS[@]} gastos de prueba" 200 "$STATUS"
req DELETE "/gastos/$ID_A";                                check "borrar dos veces → 404" 404 "$STATUS"
IDS=()
for id in "${REGLAS[@]}"; do req DELETE "/reglas/$id"; check "DELETE /reglas/$id → 200" 200 "$STATUS"; done
REGLAS=()
resumen ""
check "el total del mes vuelve al valor inicial" "$TOTAL0" "$(printf '%s' "$BODY" | jx 'd.total')"
req GET /ruta-que-no-existe;                               check "ruta desconocida → 404" 404 "$STATUS"

printf '\n%s\n' "────────────────────────────"
if [ "$FAIL" -eq 0 ]; then printf '%sTODO OK%s — %d chequeos\n' "$GREEN" "$OFF" "$PASS"; else printf '%s%d FALLARON%s de %d\n' "$RED" "$FAIL" "$OFF" $((PASS+FAIL)); fi
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# =============================================================================
# verificar_repo.sh — revisa lo que se va a subir a GitHub (no necesita Docker).
# Uso:  ./verificar_repo.sh        (antes de git add / git push)
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FALLAS=0; AVISOS=0
ok()    { printf '  \033[32mOK   \033[0m %s\n' "$*"; }
fail()  { printf '  \033[31mFALLA\033[0m %s\n' "$*"; FALLAS=$((FALLAS+1)); }
warn()  { printf '  \033[33mAVISO\033[0m %s\n' "$*"; AVISOS=$((AVISOS+1)); }

echo "== Verificación del repositorio =="
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { fail "esto no es un repositorio git (git init)"; exit 1; }

# Archivos que 'git add .' incluiría (respeta .gitignore)
mapfile_list() { git ls-files --cached --others --exclude-standard; }
LISTA="$(mapfile_list)"

# 1. archivos obligatorios
for f in docker-compose.yml Dockerfile cargar.sh sql/1_base.sql sql/2_dpa.sql sql/3_osm.sql sql/4_gtfs_tablas.sql sql/5_gtfs.sql sql/6_indices.sql README.md .gitignore .gitattributes verificar.sh; do
  if grep -qxF "$f" <<<"$LISTA"; then ok "se versiona $f"; else fail "falta (o está ignorado) $f"; fi
done

# 2. datos fuente NO versionados (-10 pts)
DATOS="$(grep -E '(^datos/|\.pbf$|\.osm$|\.zip$|(^|/)osm_[^/]*\.gpkg$|(^|/)comunas_cl\.sql$)' <<<"$LISTA" || true)"
if [[ -z "$DATOS" ]]; then ok "ningún dato fuente (.pbf, .zip, osm_*.gpkg, comunas_cl.sql, datos/) quedaría versionado"
else fail "datos fuente que se subirían (descuento -10):"; sed 's/^/        /' <<<"$DATOS"; fi

# 3. archivos grandes
GRANDES=""
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  sz=$(wc -c < "$f"); (( sz > 50*1024*1024 )) && GRANDES+="$f ($((sz/1024/1024)) MB)"$'\n'
done <<<"$LISTA"
[[ -z "$GRANDES" ]] && ok "ningún archivo > 50 MB" || { fail "archivos > 50 MB (GitHub rechaza > 100 MB):"; sed 's/^/        /' <<<"$GRANDES"; }

# 4. .gitignore cubre lo importante
for p in datos/ '*.pbf' '*.zip' 'comunas_cl.sql'; do
  grep -qxF "$p" .gitignore && ok ".gitignore contiene $p" || fail ".gitignore no contiene $p"
done
grep -qE '^salidas/?$' .gitignore && fail "salidas/ está ignorado: ahí van los GeoPackage de los mapas (deben versionarse)" || ok "salidas/ no está ignorado"

# 5. fin de línea y permiso de ejecución de los scripts
for s in cargar.sh verificar.sh verificar_repo.sh; do
  [[ -f "$s" ]] || continue
  if grep -q $'\r' "$s"; then fail "$s tiene fin de línea CRLF (corrige: sed -i 's/\\r\$//' $s)"; else ok "$s con fin de línea LF"; fi
  modo="$(git ls-files -s "$s" | cut -d' ' -f1)"
  if [[ -z "$modo" ]]; then warn "$s aún no está en git: agrégalo con  git add --chmod=+x $s"
  elif [[ "$modo" == "100755" ]]; then ok "$s versionado como ejecutable"
  else fail "$s versionado SIN permiso de ejecución (en Linux daría 'Permission denied'): git update-index --chmod=+x $s"; fi
done

# 6. README
if [[ -f README.md ]]; then
  for h in 'reproducir' 'Fuentes' 'Decisiones' 'no funcion' 'Tablas'; do
    grep -qi "$h" README.md && ok "README menciona '$h'" || fail "README no menciona '$h'"
  done
  grep -q 'ESTADO:BEGIN' README.md && ok "README tiene el bloque de estado" || fail "README sin marcadores ESTADO:BEGIN/END"
  if grep -q 'Fuentes' README.md && ! grep -q '| fuente_osm ' README.md; then
    warn "el bloque de estado del README está vacío: corre ./verificar.sh"
  fi
  n=$(grep -c 'COMPLETAR' README.md || true)
  (( n > 0 )) && warn "README tiene $n marca(s) 'COMPLETAR' (integrantes, link del repo, pendientes)" || ok "README sin marcas 'COMPLETAR'"
fi
[[ -f salidas/estado_carga.md ]] && ok "existe salidas/estado_carga.md" || warn "falta salidas/estado_carga.md (corre ./verificar.sh)"

# 7. remoto
if git remote -v | grep -q .; then ok "remoto configurado: $(git remote get-url origin 2>/dev/null)"
else warn "sin remoto: git remote add origin <url>. El repo debe ser PÚBLICO (abre el link en una ventana de incógnito)"; fi

echo
(( FALLAS > 0 )) && { printf '\033[31m%d FALLA(S), %d aviso(s).\033[0m No subir todavía.\n' "$FALLAS" "$AVISOS"; exit 1; }
printf '\033[32mSin fallas\033[0m (%d aviso(s)).\n' "$AVISOS"

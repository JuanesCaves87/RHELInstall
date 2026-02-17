#!/usr/bin/env bash
set -euo pipefail

# =========================
# MISP install for RHEL 8 (MISP-RPM / amuehlem)
# Interactive + idempotent-ish
# =========================

LOG_FILE="/var/log/misp_install_rhel8.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- Helpers ----------
color() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
info()  { color "1;34" "[INFO]  $*"; }
warn()  { color "1;33" "[WARN]  $*"; }
err()   { color "1;31" "[ERROR] $*"; }
ok()    { color "1;32" "[OK]    $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Ejecuta como root: sudo bash $0"
    exit 1
  fi
}

ask() {
  # ask "Prompt" "default"
  local prompt="$1"
  local def="${2:-}"
  local ans
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " ans || true
    echo "${ans:-$def}"
  else
    read -r -p "$prompt: " ans || true
    echo "$ans"
  fi
}

ask_yn() {
  # ask_yn "Question" "y|n"
  local q="$1"
  local def="${2:-y}"
  local ans
  while true; do
    ans="$(ask "$q (y/n)" "$def")"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Responde y/n." ;;
    esac
  done
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

detect_rhel8() {
  if [[ ! -f /etc/redhat-release ]]; then
    err "No detecto /etc/redhat-release. ¿Seguro es RHEL?"
    exit 1
  fi
  info "Sistema: $(cat /etc/redhat-release)"
  if ! grep -qE 'release 8\.' /etc/redhat-release; then
    warn "No parece RHEL 8.x. El script está pensado para RHEL 8."
    if ! ask_yn "¿Continuar de todos modos?" "n"; then
      exit 1
    fi
  fi
}

dnf_update() {
  info "Actualizando sistema (dnf update -y)..."
  dnf -y update
  ok "Sistema actualizado."
}

enable_codeready() {
  info "Habilitando CodeReady Builder (requerido para algunas deps)."
  if ! cmd_exists subscription-manager; then
    warn "subscription-manager no está disponible. Si usas Satellite, habilita CodeReady Builder ahí."
    return 0
  fi

  local arch
  arch="$(uname -m)"

  # Canonical repo id in RHEL8:
  # codeready-builder-for-rhel-8-x86_64-rpms / codeready-builder-for-rhel-8-aarch64-rpms, etc.
  local repo="codeready-builder-for-rhel-8-${arch}-rpms"

  info "Intentando: subscription-manager repos --enable ${repo}"
  set +e
  subscription-manager repos --enable "${repo}"
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "No pude habilitar ${repo}. Revisa que tu suscripción esté activa y tengas acceso a ese repo."
    warn "Puedes validar con: subscription-manager status"
    if ! ask_yn "¿Continuar de todos modos?" "y"; then
      exit 1
    fi
  else
    ok "CodeReady Builder habilitado: ${repo}"
  fi
}

install_prereqs() {
  info "Instalando utilidades base..."
  dnf -y install curl wget ca-certificates gnupg2 policycoreutils-python-utils firewalld yum-utils
  ok "Utilidades base instaladas."
}

install_misp_repo_release() {
  info "Instalando el 'misp-release' RPM (configura el repo de MISP-RPM)."

  # Según las instrucciones / upgrade del repo, el release RPM para EL8 se instala desde repo.misp-project.ch :contentReference[oaicite:1]{index=1}
  local default_release_url="https://repo.misp-project.ch/yum/misp8/misp-release-latest.el8.noarch.rpm"
  local release_url
  release_url="$(ask "URL del misp-release RPM" "$default_release_url")"

  info "Descargando e instalando: $release_url"
  dnf -y install "$release_url"
  ok "misp-release instalado (repo configurado)."
}

install_misp_packages() {
  info "Instalando paquetes MISP y servicios requeridos..."
  # Nombres típicos al usar el repo MISP-RPM. Ajusta si tu repo usa un nombre distinto.
  # Hay que revisar la configuracion de php y su instalacion, cehca el archivo php.txt antes de ejecutar
  dnf -y install \
    httpd mod_ssl \
    redis \
    mariadb-server \
    cronie \
    misp

  ok "Paquetes instalados."
}

configure_services_base() {
  info "Habilitando y arrancando servicios: firewalld, redis, mariadb, httpd..."
  systemctl enable --now firewalld || true
  systemctl enable --now redis
  systemctl enable --now mariadb
  systemctl enable --now httpd
  ok "Servicios base listos."
}

firewall_open_ports() {
  info "Configurando firewall (HTTP/HTTPS)..."
  firewall-cmd --permanent --add-service=http  || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
  ok "Firewall: HTTP/HTTPS permitidos."
}

selinux_tweaks() {
  if [[ -f /etc/selinux/config ]]; then
    info "SELinux: aplicando booleans recomendados para Apache/MISP (sin deshabilitar SELinux)."
    setsebool -P httpd_can_network_connect on || true
    setsebool -P httpd_can_sendmail on || true
    ok "SELinux booleans aplicados (si estaban disponibles)."
  fi
}

mysql_secure_like() {
  info "Configurando MariaDB local para MISP."

  local db_name db_user db_pass db_root_pass
  db_name="$(ask "Nombre de la BD para MISP" "misp")"
  db_user="$(ask "Usuario de BD para MISP" "misp")"

  if ask_yn "¿Generar password aleatorio para el usuario BD?" "y"; then
    db_pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
    info "Password generado para ${db_user}: ${db_pass}"
  else
    db_pass="$(ask "Password para ${db_user}" "")"
    if [[ -z "$db_pass" ]]; then
      err "Password vacío no permitido."
      exit 1
    fi
  fi

  if ask_yn "¿Asignar/establecer password de root de MariaDB ahora?" "y"; then
    if ask_yn "¿Generar password aleatorio para root de MariaDB?" "y"; then
      db_root_pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
      info "Password generado para root MariaDB: ${db_root_pass}"
    else
      db_root_pass="$(ask "Password para root MariaDB" "")"
    fi

    # Intenta setear password de root si está vacío / socket auth:
    set +e
    mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${db_root_pass}'; FLUSH PRIVILEGES;" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      warn "No pude cambiar el password de root directamente (puede estar usando auth_socket u otra config)."
      warn "Continuaré intentando operar como root sin password (si es posible)."
      db_root_pass=""
    fi
    set -e
  else
    db_root_pass=""
  fi

  local mysql_root_args=(-uroot)
  [[ -n "$db_root_pass" ]] && mysql_root_args+=("-p${db_root_pass}")

  info "Creando BD/usuario y permisos..."
  mysql "${mysql_root_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql "${mysql_root_args[@]}" -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
  mysql "${mysql_root_args[@]}" -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost'; FLUSH PRIVILEGES;"
  ok "MariaDB: BD y usuario listos."

  # Guardar vars para config MISP
  export MISP_DB_NAME="$db_name"
  export MISP_DB_USER="$db_user"
  export MISP_DB_PASS="$db_pass"
}

configure_misp_app() {
  info "Configurando archivos de MISP (database.php y baseurl)."

  local misp_root="/var/www/MISP"
  if [[ ! -d "$misp_root" ]]; then
    warn "No existe $misp_root. Tu paquete RPM podría usar otra ruta."
    misp_root="$(ask "Ruta de instalación de MISP" "/var/www/MISP")"
  fi

  local db_cfg="${misp_root}/app/Config/database.php"
  local core_cfg="${misp_root}/app/Config/config.php"

  if [[ ! -f "$db_cfg" ]]; then
    warn "No encuentro $db_cfg. Puede que el RPM lo genere distinto."
  fi
  if [[ ! -f "$core_cfg" ]]; then
    warn "No encuentro $core_cfg. Puede que el RPM lo genere distinto."
  fi

  local baseurl
  baseurl="$(ask "Base URL (ej: https://misp.tudominio.local)" "https://$(hostname -f)")"

  # database.php: reemplazos básicos (funciona si el archivo contiene esos tokens)
  if [[ -f "$db_cfg" ]]; then
    info "Editando $db_cfg ..."
    cp -a "$db_cfg" "${db_cfg}.bak.$(date +%F_%H%M%S)"

    # Intento de reemplazo conservador:
    sed -i \
      -e "s/'database' => '[^']*'/'database' => '${MISP_DB_NAME:-misp}'/g" \
      -e "s/'login' => '[^']*'/'login' => '${MISP_DB_USER:-misp}'/g" \
      -e "s/'password' => '[^']*'/'password' => '${MISP_DB_PASS:-}'/g" \
      "$db_cfg" || true

    ok "database.php actualizado (backup creado)."
  fi

  # config.php baseurl
  if [[ -f "$core_cfg" ]]; then
    info "Editando $core_cfg ..."
    cp -a "$core_cfg" "${core_cfg}.bak.$(date +%F_%H%M%S)"

    # MISP suele tener: 'baseurl' => '...'
    sed -i \
      -e "s/'baseurl' => '[^']*'/'baseurl' => '${baseurl//\//\\/}'/g" \
      "$core_cfg" || true

    ok "config.php actualizado (backup creado)."
  fi

  # Permisos típicos
  info "Ajustando permisos de MISP..."
  chown -R apache:apache "$misp_root" || true
  find "$misp_root" -type d -exec chmod 0750 {} \; || true
  find "$misp_root" -type f -exec chmod 0640 {} \; || true
  ok "Permisos aplicados (si fue posible)."

  info "Reiniciando httpd..."
  systemctl restart httpd
  ok "httpd reiniciado."

  info "Base URL configurada: $baseurl"
  info "Si el RPM no generó los archivos esperados, revisa manualmente:"
  info "  - $db_cfg"
  info "  - $core_cfg"
}

print_final_notes() {
  echo
  ok "Instalación finalizada (con lo que se pudo automatizar)."
  echo
  info "Siguientes pasos recomendados:"
  echo "  1) Abre en navegador: https://$(hostname -f)/"
  echo "  2) Revisa logs:"
  echo "     - $LOG_FILE"
  echo "     - /var/log/httpd/error_log"
  echo "     - /var/log/mariadb/mariadb.log (si existe)"
  echo
  info "Si quieres módulos (misp-modules), normalmente se instalan por separado (no siempre vienen como RPM en este enfoque)."
  echo
  warn "Tip: si tu RHEL8 está muy restringido (sin repos externos), confirma que el release RPM del repo MISP esté accesible. :contentReference[oaicite:2]{index=2}"
}

main() {
  need_root
  detect_rhel8

  info "Log: $LOG_FILE"
  echo

  if ask_yn "¿Actualizar el sistema (dnf update) ahora?" "y"; then
    dnf_update
  fi

  install_prereqs
  enable_codeready

  install_misp_repo_release

  if ask_yn "¿Instalar paquetes MISP ahora?" "y"; then
    install_misp_packages
  else
    warn "Saltaste instalación de paquetes. No puedo continuar con configuración completa."
    exit 0
  fi

  configure_services_base
  firewall_open_ports
  selinux_tweaks

  if ask_yn "¿Configurar base de datos local (MariaDB en este host)?" "y"; then
    mysql_secure_like
  else
    warn "Elegiste DB externa: deberás editar database.php manualmente con host/usuario/password."
  fi

  if ask_yn "¿Aplicar configuración MISP (database.php + baseurl + permisos)?" "y"; then
    configure_misp_app
  else
    warn "Configuración MISP omitida. Tendrás que configurar database.php y config.php manualmente."
  fi

  print_final_notes
}

main "$@"


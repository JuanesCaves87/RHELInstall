#!/bin/bash

# Script interactivo para solucionar dependencias de MISP en EL8 (2026)
# Autor: Asistente AI

set -e

echo "--- Instalador de Dependencias MISP para Enterprise Linux 8 ---"
echo "Este script configurará EPEL, Remi (PHP 8.3) y el repositorio de MISP."
read -p "¿Desea continuar? (s/n): " confirmacion

if [[ $confirmacion != "s" && $confirmacion != "S" ]]; then
    echo "Instalación cancelada."
    exit 0
fi

# 1. Identificar el sistema y habilitar repositorio de herramientas (PowerTools/CRB)
echo "[1/5] Configurando repositorio de herramientas de desarrollo..."
OS_ID=$(grep -w ID /etc/os-release | cut -d= -f2 | tr -d '"')

if [[ "$OS_ID" == "rhel" ]]; then
    sudo subscription-manager repos --enable codeready-builder-for-rhel-8-x86_64-rpms
elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rocky" || "$OS_ID" == "almalinux" ]]; then
    sudo dnf install -y 'dnf-command(config-manager)'
    sudo dnf config-manager --set-enabled powertools || sudo dnf config-manager --set-enabled crb
fi

# 2. Instalar EPEL y Remi
echo "[2/5] Instalando repositorios EPEL y Remi..."
sudo dnf install -y dl.fedoraproject.org
sudo dnf install -y rpms.remirepo.net

# 3. Configurar el módulo PHP 8.3
echo "[3/5] Configurando módulo PHP 8.3 de Remi..."
sudo dnf module reset php -y
sudo dnf module enable php:remi-8.3 -y

# 4. Instalar el repositorio oficial de MISP
echo "[4/5] Añadiendo repositorio oficial de MISP..."
sudo dnf install -y repo.misp-project.ch

# 5. Instalación final
echo "[5/5] Intentando instalar MISP y sus dependencias (supervisor, php83-*, etc)..."
sudo dnf makecache
sudo dnf install -y misp

echo "---------------------------------------------------------------"
echo "Proceso finalizado. Si no hubo errores, MISP está instalado."
echo "Recuerde revisar la guía oficial en https://misp-project.org"


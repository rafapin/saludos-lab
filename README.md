# Laboratorio saludos en Azure con GitHub Actions

Este repositorio está preparado para el Entregable 1 del diplomado. Publica una página sencilla mediante Application Gateway; la página consulta una API en otra VM y la API consulta PostgreSQL privado. Los workflows construyen dos imágenes con Docker básico, las publican en Docker Hub y las despliegan con runners de GitHub Actions instalados en las VM.

El código es deliberadamente pequeño para que las evidencias se concentren en infraestructura, red y CI/CD. No hay recursos creados por guardar o subir estos archivos: Azure se aprovisiona al ejecutar el script con `-Apply`.

**Estado de validación:** las imágenes, las tres pruebas unitarias y el flujo integrado frontend → backend → PostgreSQL pasaron localmente el 13 de octubre de 2026. El aprovisionamiento en Azure depende de cuota, disponibilidad regional y revisión de costos.

## Qué se aprovisiona

| Componente | Nombre | Función |
| --- | --- | --- |
| Grupo de recursos | `rg-saludos-e1-20261013` | Aísla el laboratorio |
| VNet | `vnet-saludos-e1`, `10.1.0.0/16` | Red privada |
| Subred gateway | `snet-appgw`, `10.1.0.0/24` | Solo Application Gateway |
| Subred frontend | `snet-frontend`, `10.1.1.0/24` | VM frontend privada |
| Subred backend | `snet-backend`, `10.1.2.0/24` | VM backend privada |
| Subred datos | `snet-postgres`, `10.1.3.0/24` | PostgreSQL Flexible Server delegado |
| NAT Gateway | `nat-saludos-e1` | Salida de las VM a GitHub y Docker Hub |
| Application Gateway | `agw-saludos-e1` | Entrada HTTP pública por el puerto 80 |
| Dos VM Ubuntu | `vm-saludos-frontend`, `vm-saludos-backend` | Docker y runners, sin IP pública |
| PostgreSQL | Nombre único generado con la suscripción | Base `saludos`, acceso privado |
| Private DNS Zone | `saludos.private.postgres.database.azure.com` | Resolver PostgreSQL dentro de la VNet |

El flujo que se prueba es **Internet → Application Gateway → Nginx frontend → API backend → PostgreSQL**. La ruta `/api/saludo` del frontend hace proxy hacia la IP privada de la VM backend, así que el navegador nunca necesita acceder directamente al backend.

## Paso 0 Revisar costo y prerrequisitos

1. Tener Azure CLI, Git, Docker Desktop y una sesión activa con `az login`. En Azure CLI, comprobar la suscripción con `az account show -o table`.
2. Estimar en la [calculadora de precios de Azure](https://azure.microsoft.com/en-us/pricing/calculator/) **dos VM con discos, PostgreSQL Flexible Server, Application Gateway Standard_v2, NAT Gateway y dos IP públicas**. El script propone East US 2 y tamaños de laboratorio; se pueden cambiar por parámetros. Todos estos componentes pueden generar cargos mientras existan.
3. Crear un [presupuesto y alertas](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets) en la suscripción o grupo de recursos. La alerta no suspende recursos ni detiene cargos.
4. Tener una clave SSH pública. Si no existe, crear primero la carpeta con `New-Item -ItemType Directory .keys -Force` y generar una para este laboratorio con `ssh-keygen -t ed25519 -f .\.keys\saludos_e1` desde la raíz del repositorio. La carpeta `.keys` está ignorada por Git.
5. Tener cuenta de GitHub y Docker Hub. No compartir contraseñas, tokens ni claves por chat o en capturas.

## Paso 1 Probar los programas localmente

Desde PowerShell, en la raíz del repositorio:

    .\scripts\smoke-local.ps1

El script construye y prueba el backend, inicia PostgreSQL, backend y frontend en una red Docker temporal, consulta `/api/saludo` y elimina esos contenedores de prueba. Debe mostrar el saludo y una hora obtenida de PostgreSQL. Usa Docker básico; no requiere Docker Compose.

Archivos principales:

- `frontend/index.html`: página de prueba.
- `frontend/default.conf.template`: proxy de `/api/` al backend privado.
- `backend/app.py`: `/live`, `/ready` y `/saludo`; las dos últimas rutas comprueban PostgreSQL.
- `backend/tests/test_app.py`: pruebas de respuestas HTTP y fallo de base de datos.

## Paso 2 Revisar y ejecutar el aprovisionamiento

La primera ejecución solo muestra la configuración prevista:

    .\infra\provision.ps1 -SshPublicKeyPath .\.keys\saludos_e1.pub

Cuando el costo esté revisado, ejecutar:

    .\infra\provision.ps1 -SshPublicKeyPath .\.keys\saludos_e1.pub -CostReviewed -Apply

El script genera una contraseña fuerte para PostgreSQL y la guarda en `.secrets/db-admin-password.txt`, archivo ignorado por Git. Se necesitará como secreto `DB_PASSWORD` de GitHub; no publicar su contenido. Si la región, el tamaño o el grupo cambian, consultar los parámetros al inicio de `infra/provision.ps1` y pasarlos en la llamada, por ejemplo `-Location eastus2 -FrontendVmSize Standard_B2s`.

El script crea primero red y NAT, después DNS y PostgreSQL, luego las VM y finalmente Application Gateway. Tarda varios minutos. Si falla a mitad de camino, revise el estado del recurso afectado antes de reejecutarlo; el script omite recursos que ya existen. **El gateway aparecerá Unhealthy hasta que el frontend esté desplegado.**

Guardar las salidas que imprime al final: `DB_HOST`, `DB_NAME`, `DB_USER`, `BACKEND_PRIVATE_IP`, `FRONTEND_PRIVATE_IP` y `APP_URL`. El servidor PostgreSQL usa TLS desde el backend. Las VM no tienen IP pública porque el script crea primero NIC privadas y las asocia a cada VM.

## Paso 3 Verificar la infraestructura en Azure

En el portal de Azure, abrir `rg-saludos-e1-20261013` y comprobar:

1. VNet con las cuatro subredes; `snet-postgres` delegada a PostgreSQL.
2. NAT Gateway asociado a frontend y backend, con su IP pública de salida.
3. NIC de las dos VM con IP privada y sin IP pública. Las VM tienen identidad administrada.
4. PostgreSQL con acceso privado y Private DNS Zone vinculada a la VNet.
5. Application Gateway con otra IP pública, backend pool de la VM frontend en puerto 8080 y probe `/health`.
6. NSG frontend: 8080 desde la subred del gateway; NSG backend: 5000 desde frontend. No se abre SSH al público.

Para comprobar Docker sin SSH público, abrir cada VM → **Run command** → **RunShellScript**, y ejecutar `docker --version && systemctl is-active docker && id azureuser`. Run Command usa el agente de la VM; [documentación de Microsoft](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command).

Capturar pantallazos de estos recursos. El gateway seguirá Unhealthy hasta el paso de despliegue.

## Paso 4 Crear los repositorios de Docker Hub

Crear **dos repositorios públicos** en tu namespace de Docker Hub:

- `TU_USUARIO/saludos-backend`
- `TU_USUARIO/saludos-frontend`

El plan usa imágenes públicas para que las VM puedan hacer `docker pull` sin credenciales de Docker Hub. Crear un token de Docker Hub con permiso de escritura para que CI pueda hacer push. Guardarlo temporalmente en tu gestor de contraseñas; nunca en un archivo del repositorio.

## Paso 5 Subir este código a GitHub

Crear un repositorio privado llamado, por ejemplo, `saludos-lab`. GitHub [advierte sobre ejecutar trabajos de repositorios públicos en runners propios persistentes](https://docs.github.com/en/actions/reference/security/secure-use). Compartirlo con los evaluadores como colaboradores; si se vuelve público después, retirar antes los runners de las VM.

Subir **el contenido de esta carpeta `saludos-lab` como raíz del repositorio**, no el PDF ni la guía externa. Desde esta carpeta:

    git init
    git branch -M main
    git add .
    git commit -m "Laboratorio saludos Azure GitHub Actions"
    git remote add origin https://github.com/TU_USUARIO/saludos-lab.git
    git push -u origin main

La primera ejecución de CI puede quedar en cola hasta que se registren los runners. Esto es normal.

## Paso 6 Configurar variables y secretos de GitHub

En **Settings → Secrets and variables → Actions** del repositorio:

| Tipo | Nombre | Valor |
| --- | --- | --- |
| Variable de repositorio | `DOCKERHUB_USERNAME` | Tu usuario de Docker Hub |
| Secreto de repositorio | `DOCKERHUB_TOKEN` | Token de escritura de Docker Hub |

En **Settings → Environments**, crear el entorno `Production`. En sus variables y secretos:

| Tipo | Nombre | Valor |
| --- | --- | --- |
| Variable | `DB_HOST` | FQDN que imprimió `provision.ps1` |
| Variable | `DB_NAME` | `saludos` |
| Variable | `DB_USER` | `saludosadmin`, salvo que hayas cambiado el parámetro |
| Variable | `BACKEND_PRIVATE_IP` | IP privada que imprimió el script |
| Secreto | `DB_PASSWORD` | Contraseña elegida al crear PostgreSQL |

No subir `.env` reales. El workflow CD crea un archivo protegido solo en la VM backend. [Guía de secretos de GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets).

## Paso 7 Registrar un runner en cada VM

En GitHub, abrir el repositorio → **Settings → Actions → Runners → New self-hosted runner → Linux x64**. Repetir el proceso para cada VM y seguir los comandos de descarga que GitHub muestre en ese momento; la versión del runner cambia con el tiempo.

Como las VM no tienen IP pública, entrar en el portal de Azure → VM → **Run command → RunShellScript**. El comando se ejecuta como root. Para cada VM:

1. Usar `infra/install-runner.sh`, que espera cloud-init, comprueba Docker, descarga la versión actual del runner desde GitHub, lo registra como `azureuser` e instala el servicio. Se puede pasar a `az vm run-command invoke --command-id RunShellScript --scripts @infra/install-runner.sh --parameters URL_DEL_REPO TOKEN_TEMPORAL frontend vm-saludos-frontend` para la VM frontend; sustituir la etiqueta y el nombre para backend.
2. En GitHub, comprobar que aparecen **Online** los runners `frontend` y `backend`. El script de cloud-init ya agrega `azureuser` al grupo Docker.

No pegues el token temporal del runner en el chat ni en las capturas. Si GitHub indica dependencias faltantes, ejecutar `./bin/installdependencies.sh` como root antes de configurar. [Guía oficial de runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners).

## Paso 8 Ejecutar CI

En GitHub → **Actions → CI → Run workflow**, elegir `main`, o hacer un nuevo push a `main`. El job corre en el runner frontend:

1. Obtiene el código.
2. Ejecuta las pruebas del backend dentro de Docker.
3. Construye frontend y backend con `docker build`.
4. Etiqueta las dos imágenes con `sha-...` y `latest`.
5. Publica ambos tags en Docker Hub.

Comprobar que CI aparece verde y que los dos repositorios de Docker Hub muestran los tags. Capturar el workflow y las páginas de Docker Hub.

## Paso 9 Ejecutar CD y verificar conexiones

Cuando CI termina correctamente en `main`, `CD.yml` se dispara automáticamente. El archivo debe existir en la rama predeterminada `main` para que [workflow_run](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run) lo ejecute.

1. El runner backend hace pull de `latest`, arranca el contenedor y verifica `/ready`, que consulta PostgreSQL por DNS privado y puerto 5432.
2. Luego el runner frontend hace pull de `latest`, arranca Nginx con la IP privada del backend y consulta `/api/saludo` a través del proxy.
3. Abrir `APP_URL` en el navegador y confirmar que aparece **Hola desde Azure** junto a una hora de PostgreSQL.
4. Volver a Application Gateway → **Backend health** y confirmar estado **Healthy**.

Como resumen de solo lectura, ejecutar `.\infra\verify.ps1`. Muestra subredes, IP privadas, PostgreSQL, salud del gateway y la respuesta pública.

Si CD falla, revisar primero el job que falla y después: runners Online, `DB_HOST`, contraseña, DNS privado, NSG, estado de contenedores y probe del gateway. `backend/app.py` devuelve 503 cuando la conexión con PostgreSQL falla, lo que ayuda a localizar el problema.

CD también permite ejecución manual con `image_tag`. Para un despliegue normal usar `latest`; para volver a una versión publicada usar su tag `sha-...` y comprobar otra vez la aplicación.

## Paso 10 Guardar evidencias y entregar

- Enlace a este repositorio y acceso a los evaluadores si sigue privado.
- Capturas del grupo, VNet/subredes, NAT, NSG, VM sin IP pública, PostgreSQL privado, Private DNS Zone, Application Gateway Healthy y métricas de Azure Monitor.
- Capturas de CI y CD verdes.
- Capturas de los dos repositorios de Docker Hub con tags `latest` y `sha-...`; enlace al perfil.
- Archivo con las seis respuestas del PDF: dificultad y facilidad, aprendizajes, mejoras, dudas, errores y su solución, y qué se necesita para replicar el ambiente.
- Compartir lo anterior con las dos direcciones indicadas en el PDF.

Después de tomar las capturas, revisar el gasto y borrar el grupo `rg-saludos-e1-20261013` con `.\infra\cleanup.ps1 -Apply`; el script comprueba el nombre, muestra los recursos y verifica la eliminación. El presupuesto solo alerta y no interrumpe la facturación.

## Fuentes de infraestructura

- [Subred dedicada y NSG de Application Gateway](https://learn.microsoft.com/en-us/azure/application-gateway/configuration-infrastructure)
- [PostgreSQL Flexible Server en una VNet privada](https://learn.microsoft.com/en-us/azure/postgresql/network/concepts-networking-private)
- [NAT Gateway y acceso saliente](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview)
- [Azure CLI para PostgreSQL privado](https://learn.microsoft.com/en-us/cli/azure/postgres/flexible-server)

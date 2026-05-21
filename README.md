# Sistema de Gestión de Despachos - Innovatech Chile

## Arquitectura del Proyecto

```
┌──────────────────────────────────────────────────────────────┐
│                    INTERNET (usuario)                         │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │   EC2 Frontend       │
              │   (Subred Pública)   │
              │   Nginx :80          │
              │   React SPA          │
              └──────────┬───────────┘
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
   ┌──────────────────┐  ┌──────────────────┐
   │ EC2 Backend       │  │ EC2 Backend       │
   │ Ventas :8080      │  │ Despachos :8081   │
   │ Spring Boot       │  │ Spring Boot       │
   └────────┬─────────┘  └────────┬─────────┘
            │                     │
            └──────────┬──────────┘
                       ▼
              ┌──────────────────┐
              │   EC2 MySQL      │
              │   :3306          │
              └──────────────────┘
```

## Estructura de Archivos

```
/
├── front_despacho/              # React + Vite + Tailwind
│   ├── Dockerfile               # Multi-stage (Node → Nginx)
│   ├── nginx.conf               # Proxy reverso a backends
│   ├── .dockerignore
│   └── src/
├── back-Ventas_SpringBoot/      # Microservicio Ventas
│   └── Springboot-API-REST/
│       ├── Dockerfile           # Multi-stage (Maven → JRE)
│       ├── .dockerignore
│       └── src/
├── back-Despachos_SpringBoot/   # Microservicio Despachos
│   └── Springboot-API-REST-DESPACHO/
│       ├── Dockerfile           # Multi-stage (Maven → JRE)
│       ├── .dockerignore
│       └── src/
├── docker-compose.yml           # Orquestación local
└── .github/workflows/
    ├── cicd-frontend.yml
    ├── cicd-backend-ventas.yml
    └── cicd-backend-despachos.yml
```

## 1. Contenedorización

### Dockerfiles (Multi-stage Build)

| Servicio | Stage 1 (Build) | Stage 2 (Runtime) | Puerto |
|----------|----------------|-------------------|--------|
| front_despacho | `node:20-alpine` → `npm run build` | `nginx:1.27-alpine` (usuario no root) | 80 |
| back-ventas | `maven:3.9-eclipse-temurin-17` → `mvn package` | `eclipse-temurin:17-jre-alpine` (usuario no root) | 8080 |
| back-despachos | `maven:3.9-eclipse-temurin-17` → `mvn package` | `eclipse-temurin:17-jre-alpine` (usuario no root) | 8081 |

**Buenas prácticas aplicadas:**
- **Multi-stage build**: Reduce la imagen final al mínimo necesario (JRE sin JDK, Nginx sin Node)
- **Usuario no root**: `adduser` + `USER appuser` para seguridad
- **Healthcheck**: Verifica que el servicio responda antes de marcarlo como saludable
- **Capas limpias**: `.dockerignore` excluye archivos innecesarios

### docker-compose.yml

```yaml
Servicios:
  - mysql: Base de datos MySQL 8
  - backend-ventas: API REST de ventas (Spring Boot)
  - backend-despachos: API REST de despachos (Spring Boot)
  - frontend: Interfaz React servida por Nginx

Redes:
  - backend_network: Red interna (solo backends y BD)
  - frontend_network: Red donde frontend ve a backends

Volúmenes:
  - mysql_data: Persistencia de la BD (named volume)
  - backend_logs: Logs de los microservicios (named volume)
```

## 2. Persistencia de Datos

Se utilizan **named volumes** en lugar de bind mounts por las siguientes razones:

| Aspecto | Named Volume | Bind Mount |
|---------|-------------|------------|
| Gestión | Docker administra automáticamente | Depende de la estructura del host |
| Portabilidad | Funciona en cualquier entorno | Requiere rutas específicas |
| Seguridad | Aislado del sistema host | Acceso directo a archivos del host |
| Backup | `docker run --volumes-from` | Copia manual de directorios |

**Volúmenes definidos:**
- `mysql_data` → `/var/lib/mysql`: Datos críticos de la base de datos
- `backend_logs` → `/app/logs`: Logs de la aplicación

## 3. Pipeline CI/CD (GitHub Actions)

### Flujo del Pipeline

```
Push en rama "deploy"
        │
        ▼
┌─────────────────┐
│ 1. Checkout     │
└────────┬────────┘
         ▼
┌─────────────────┐
│ 2. Login Docker │
│    Hub          │
└────────┬────────┘
         ▼
┌─────────────────┐
│ 3. Build + Push │
│    :latest      │
│    :{sha}       │
└────────┬────────┘
         ▼
┌─────────────────┐
│ 4. Deploy via   │
│    SSM a EC2    │
└────────┬────────┘
         ▼
┌─────────────────┐
│ 5. docker pull  │
│ 6. docker stop  │
│ 7. docker run   │
└─────────────────┘
```

### Workflows

| Workflow | Trigger (paths) | Imagen destino |
|----------|----------------|----------------|
| `cicd-frontend.yml` | `front_despacho/**` | `tienda-frontend-despacho` |
| `cicd-backend-ventas.yml` | `back-Ventas_SpringBoot/**` | `tienda-backend-ventas` |
| `cicd-backend-despachos.yml` | `back-Despachos_SpringBoot/**` | `tienda-backend-despachos` |

### Secrets Requeridos

| Secret | Descripción |
|--------|-------------|
| `DOCKER_USERNAME` | Usuario de Docker Hub |
| `DOCKER_PASSWORD` | Token de acceso de Docker Hub |
| `AWS_ACCESS_KEY_ID` | Credenciales AWS |
| `AWS_SECRET_ACCESS_KEY` | Credenciales AWS |
| `AWS_SESSION_TOKEN` | Token de sesión AWS (si aplica) |

## 4. Despliegue en AWS

### Infraestructura (CloudFormation)

```
VPC (10.0.0.0/16)
├── Subred Pública (10.0.1.0/24)
│   └── EC2 Frontend (con Elastic IP)
├── Subred Privada App (10.0.2.0/24)
│   ├── EC2 Backend Ventas
│   └── EC2 Backend Despachos
└── Subred Privada Datos (10.0.3.0/24)
    └── EC2 MySQL
```

### Security Groups (Tráfico Encadenado)

```
Internet → sg-web (80) → EC2 Frontend
sg-web (80/3001) → sg-app → EC2 Backends
sg-app (3306) → sg-datos → EC2 MySQL
```

### Comandos de Despliegue Manual

```bash
# 1. Construir imágenes
docker compose build

# 2. Iniciar servicios localmente
docker compose up -d

# 3. Verificar estado
docker compose ps
docker compose logs -f

# 4. Detener servicios
docker compose down
```

## 5. Variables de Entorno

| Variable | Descripción | Valor por defecto |
|----------|-------------|-------------------|
| `DB_ENDPOINT` | Host de MySQL | `localhost` |
| `DB_PORT` | Puerto de MySQL | `3306` |
| `DB_NAME` | Nombre de base de datos | `tienda_perritos` |
| `DB_USERNAME` | Usuario MySQL | `root` |
| `DB_PASSWORD` | Contraseña MySQL | `admin123` |

## 6. Requisitos

- Docker 24+
- Docker Compose v2
- Cuenta Docker Hub
- Cuenta AWS Academy
- Git

## 7. Autores

- Evaluación Parcial N°2 - ISY1101 Introducción a Herramientas DevOps

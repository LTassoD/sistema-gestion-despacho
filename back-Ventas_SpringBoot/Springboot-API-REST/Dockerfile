# ==========================================
# STAGE 1: Build con Maven + JDK 17
# ==========================================
FROM maven:3.9-eclipse-temurin-17 AS builder

WORKDIR /build

COPY pom.xml .
RUN mvn dependency:go-offline -B

COPY src ./src
RUN mvn clean package -DskipTests -B

# ==========================================
# STAGE 2: Runtime con JRE 17
# ==========================================
FROM eclipse-temurin:17-jre-alpine AS runtime

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=builder /build/target/*.jar app.jar

RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

ENV DB_ENDPOINT=localhost \
    DB_PORT=3306 \
    DB_NAME=despachos_db \
    DB_USERNAME=root \
    DB_PASSWORD=admin123

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget -qO- http://localhost:8080/api/health || exit 1

ENTRYPOINT ["java", "-jar", "app.jar"]

# ==========================================
# STAGE 1: Build con Node 20
# ==========================================
FROM node:20-alpine AS builder

WORKDIR /build

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build

# ==========================================
# STAGE 2: Servir con Nginx (usuario no root)
# ==========================================
FROM nginx:1.27-alpine AS runtime

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

RUN rm -rf /usr/share/nginx/html/*

COPY --from=builder /build/dist /usr/share/nginx/html

COPY nginx.conf /etc/nginx/conf.d/default.conf

RUN chown -R appuser:appgroup /usr/share/nginx/html && \
    chmod -R 755 /usr/share/nginx/html && \
    touch /var/run/nginx.pid && \
    chown -R appuser:appgroup /var/run/nginx.pid /var/cache/nginx

USER appuser

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:80/ || exit 1

CMD ["nginx", "-g", "daemon off;"]

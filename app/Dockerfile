# nginx unprivileged : ecoute sur 8080 et tourne en uid 101.
# Compatible avec runAsNonRoot + readOnlyRootFilesystem et avec Pod Security
# Admission restricted sur le namespace demo.
FROM nginxinc/nginx-unprivileged:1.29-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
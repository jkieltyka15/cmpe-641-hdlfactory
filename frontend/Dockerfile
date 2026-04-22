# Frontend container image for serving static HDLFACTORY assets via nginx.
FROM nginx:alpine

# Copy static app files and nginx route/proxy configuration.
COPY index.html /usr/share/nginx/html/index.html
COPY umbc.png /usr/share/nginx/html/umbc.png
COPY nginx.conf /etc/nginx/conf.d/default.conf

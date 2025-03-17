version: '3.8'

services:
  hello-world:
    image: nginxdemos/hello:latest
    container_name: hello-world
    restart: unless-stopped
    ports:
      - "80:80"
    networks:
      - app-network
  
  frontend:
    image: ${dockerhub_username}/tradevis-frontend:latest
    container_name: tradevis-frontend
    restart: unless-stopped
    ports:
      - "3000:80"
    networks:
      - app-network

networks:
  app-network:
    driver: bridge 
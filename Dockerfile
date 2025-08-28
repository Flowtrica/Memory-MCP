FROM node:20-alpine

WORKDIR /app

# Install required packages
RUN npm install -g @modelcontextprotocol/server-memory mcp-proxy

# Create data directory  
RUN mkdir -p /app/data

# Set environment
ENV MEMORY_FILE_PATH=/app/data/memory.json
ENV PORT=8081

# Expose port
EXPOSE 8081

# Use mcp-proxy to handle HTTP/SSE transport
CMD ["mcp-proxy", "--host=0.0.0.0", "--port=8081", "--server=sse", "npx", "@modelcontextprotocol/server-memory"]

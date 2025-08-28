FROM node:20-alpine

WORKDIR /app

# Install MCP memory server and dependencies
RUN npm init -y && \
    npm install express cors @modelcontextprotocol/server-memory @modelcontextprotocol/sdk

# Create the proper MCP server with correct initialization
RUN cat > server.js << 'EOF'
const express = require('express');
const cors = require('cors');
const fs = require('fs');
const { spawn } = require('child_process');

const app = express();
const PORT = process.env.PORT || 8081;
const MEMORY_FILE = process.env.MEMORY_FILE_PATH || '/app/data/memory.json';

app.use(cors());
app.use(express.json());

// Initialize memory file
const initMemory = () => {
  if (!fs.existsSync('/app/data')) {
    fs.mkdirSync('/app/data', { recursive: true });
  }
  if (!fs.existsSync(MEMORY_FILE)) {
    fs.writeFileSync(MEMORY_FILE, JSON.stringify({
      entities: [],
      relations: [],
      observations: []
    }, null, 2));
  }
};

// Health endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    timestamp: new Date().toISOString(),
    memoryFile: MEMORY_FILE,
    endpoints: { health: '/health', sse: '/sse', info: '/' }
  });
});

// Info endpoint
app.get('/', (req, res) => {
  res.json({
    name: 'MCP Memory Server',
    version: '1.0.0',
    transport: 'SSE',
    protocol: 'Model Context Protocol',
    endpoints: { health: '/health', sse: '/sse' },
    timestamp: new Date().toISOString()
  });
});

// SSE endpoint with proper MCP protocol handling
app.get('/sse', (req, res) => {
  console.log('New MCP connection from:', req.ip);
  
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Cache-Control',
  });

  // Start the MCP memory server process
  const mcpServer = spawn('npx', ['@modelcontextprotocol/server-memory'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { 
      ...process.env,
      MEMORY_FILE_PATH: MEMORY_FILE
    }
  });

  let isInitialized = false;
  let messageId = 0;

  // Handle MCP server stdout (JSON-RPC messages)
  mcpServer.stdout.on('data', (data) => {
    const output = data.toString().trim();
    console.log('MCP Server output:', output);
    
    const lines = output.split('\n').filter(line => line.trim());
    lines.forEach(line => {
      try {
        const message = JSON.parse(line);
        res.write(`data: ${JSON.stringify(message)}\n\n`);
        
        // After initialization, request tools list
        if (message.result && message.result.capabilities && !isInitialized) {
          isInitialized = true;
          console.log('MCP server initialized, requesting tools...');
          
          // Send tools/list request
          const toolsRequest = {
            jsonrpc: '2.0',
            id: ++messageId,
            method: 'tools/list',
            params: {}
          };
          
          setTimeout(() => {
            mcpServer.stdin.write(JSON.stringify(toolsRequest) + '\n');
          }, 500);
        }
      } catch (e) {
        // Not JSON, might be logs - ignore
      }
    });
  });

  // Handle MCP server stderr (logs)
  mcpServer.stderr.on('data', (data) => {
    const output = data.toString().trim();
    console.log('MCP Server log:', output);
  });

  mcpServer.on('error', (error) => {
    console.error('Failed to start MCP server:', error);
    const errorMsg = {
      jsonrpc: '2.0',
      error: {
        code: -32000,
        message: 'Failed to start MCP server',
        data: error.message
      }
    };
    res.write(`data: ${JSON.stringify(errorMsg)}\n\n`);
  });

  // Initialize the MCP connection
  const initializeMessage = {
    jsonrpc: '2.0',
    id: ++messageId,
    method: 'initialize',
    params: {
      protocolVersion: '2024-11-05',
      capabilities: {},
      clientInfo: {
        name: 'mcp-memory-remote',
        version: '1.0.0'
      }
    }
  };

  // Send initialize after a short delay
  setTimeout(() => {
    console.log('Sending initialize message...');
    mcpServer.stdin.write(JSON.stringify(initializeMessage) + '\n');
  }, 1000);

  // Handle connection cleanup
  const cleanup = () => {
    console.log('Cleaning up MCP connection');
    if (mcpServer && !mcpServer.killed) {
      mcpServer.kill('SIGTERM');
    }
  };

  req.on('close', cleanup);
  req.on('error', (err) => {
    console.error('SSE connection error:', err.message);
    cleanup();
  });

  // Keep connection alive (reduced frequency to avoid spam)
  const keepAlive = setInterval(() => {
    if (!res.destroyed && res.writable) {
      res.write(': keepalive\n\n');
    } else {
      clearInterval(keepAlive);
    }
  }, 45000);

  req.on('close', () => {
    clearInterval(keepAlive);
  });
});

// Initialize and start
initMemory();
app.listen(PORT, '0.0.0.0', () => {
  console.log(`MCP Memory Server running on port ${PORT}`);
  console.log(`Health: http://localhost:${PORT}/health`);
  console.log(`SSE: http://localhost:${PORT}/sse`);
  console.log(`Memory file: ${MEMORY_FILE}`);
});
EOF

# Create data directory
RUN mkdir -p /app/data

EXPOSE 8081
CMD ["node", "server.js"]

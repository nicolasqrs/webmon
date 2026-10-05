const fs = require('fs/promises');
const express = require('express');
const cors = require('cors');
const client = require('prom-client');
const { initDb, getTasks, createTask, updateTask, deleteTask } = require('./db');
const { mergeFailureStates } = require('./container-state');
const app = express();
app.use(cors());
app.use(express.json());
// === Prometheus metrics ===
const register = new client.Registry();
client.collectDefaultMetrics({ register });
const httpRequests = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status'],
  registers: [register]
});
const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration',
  labelNames: ['method', 'route'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5],
  registers: [register]
});
app.use((req, res, next) => {
  const end = httpDuration.startTimer({ method: req.method, route: req.path });
  res.on('finish', () => {
    httpRequests.inc({ method: req.method, route: req.path, status: res.statusCode });
    console.log(`${new Date().toISOString()} ${req.method} ${req.path} ${res.statusCode}`);
    end();
  });
  next();
});

// === Docker containers discovery ===

// Emplacement du fichier généré par webmon-monitor.
// La variable d'environnement permet de changer ce chemin
// sans modifier le code.
const CONTAINERS_FILE =
  process.env.CONTAINERS_FILE || '/runtime/containers.json';

// Fichier contenant les résultats des contrôles fonctionnels.
const FUNCTIONAL_FILE =
  process.env.FUNCTIONAL_FILE || '/runtime/functional.json';


// Fichier contenant les contrôles HTTP détectés automatiquement.
const HTTP_FUNCTIONAL_FILE =
  process.env.HTTP_FUNCTIONAL_FILE || '/runtime/http-functional.json';
const FAILURE_STATE_FILE =
  process.env.FAILURE_STATE_FILE || '/runtime/failure-state.json';

app.get('/api/containers', async (req, res) => {
  try {

    // ========================================================
    // 1. Lecture des conteneurs Docker découverts
    // ========================================================

    const containersData =
      await fs.readFile(CONTAINERS_FILE, 'utf8');

    const containers =
      JSON.parse(containersData);


    // ========================================================
    // Masquer les conteneurs internes de WebMon
    // ========================================================
    //
    // Les composants techniques portant le label :
    //
    // webmon.internal=true
    //
    // restent visibles par webmon-monitor et Docker,
    // mais ne sont pas envoyés au dashboard utilisateur.
    // ========================================================

    const visibleContainers = containers.filter(container => {

      const labels = String(container.Labels || '')
        .split(',')
        .map(label => label.trim());

      return !labels.includes('webmon.internal=true');
    });


    // ========================================================
    // 2. Contrôles fonctionnels WebMon personnalisés
    // ========================================================
    //
    // Exemple actuel :
    // worker-a / worker-b avec heartbeat.
    // ========================================================

    let functionalStates = [];

    try {

      const functionalData =
        await fs.readFile(FUNCTIONAL_FILE, 'utf8');

      functionalStates =
        JSON.parse(functionalData);

    } catch (e) {

      console.warn(
        'functional.json unavailable - continuing without custom checks'
      );
    }


    // ========================================================
    // 3. Contrôles HTTP automatiques
    // ========================================================
    //
    // Exemple :
    // site-apache -> http://host.docker.internal:8081/
    // ========================================================

    let httpStates = [];

    try {

      const httpData =
        await fs.readFile(HTTP_FUNCTIONAL_FILE, 'utf8');

      httpStates =
        JSON.parse(httpData);

    } catch (e) {

      console.warn(
        'http-functional.json unavailable - continuing without HTTP checks'
      );
    }


    // ========================================================
    // 4. Indexation par nom de conteneur
    // ========================================================

    const functionalByName = new Map();

    for (const item of functionalStates) {
      functionalByName.set(item.name, item);
    }


    const httpByName = new Map();

    for (const item of httpStates) {
      httpByName.set(item.name, item);
    }


    // ========================================================
    // 5. Fusion des informations
    // ========================================================

    const result = visibleContainers.map(container => {

      const name = container.Names;

      const customFunctional =
        functionalByName.get(name);

      const httpFunctional =
        httpByName.get(name);


      // ======================================================
      // PRIORITE 1
      // Contrôle WebMon personnalisé
      // ======================================================

      if (customFunctional) {

        return {
          ...container,

          webmon: {
            configured: true,

            source: 'webmon',

            running:
              customFunctional.running === 1,

            functional:
              customFunctional.functional === 1,

            heartbeat_age:
              customFunctional.heartbeat_age,

            max_age:
              customFunctional.max_age
          }
        };
      }


      // ======================================================
      // PRIORITE 2
      // Healthcheck Docker natif
      // ======================================================

      const healthStatus =
        (container.HealthStatus || '').toLowerCase();


      if (
        healthStatus === 'healthy' ||
        healthStatus === 'unhealthy' ||
        healthStatus === 'starting'
      ) {

        return {
          ...container,

          webmon: {
            configured: true,

            source: 'docker-healthcheck',

            health_status:
              healthStatus,

            running:
              container.State === 'running',

            functional:
              container.State === 'running' && healthStatus === 'healthy'
          }
        };
      }


      // ======================================================
      // PRIORITE 3
      // Contrôle HTTP automatique WebMon
      // ======================================================

      if (httpFunctional) {

        return {
          ...container,

          webmon: {
            configured: true,

            source: 'auto-http',

            running:
              httpFunctional.running === 1,

            functional:
              httpFunctional.functional === 1,

            mode:
              httpFunctional.mode,

            port:
              httpFunctional.port,

            url:
              httpFunctional.url,

            status_code:
              httpFunctional.status_code
          }
        };
      }


      // ======================================================
      // PRIORITE 4
      // Aucun contrôle fonctionnel trouvé
      // ======================================================

      return {
        ...container,

        webmon: {
          configured: false,
          source: null
        }
      };
    });


    // ========================================================
    // 6. Réponse au frontend
    // ========================================================

    let failureStates = [];
    try {
      const data = JSON.parse(await fs.readFile(FAILURE_STATE_FILE, 'utf8'));
      if (Array.isArray(data)) failureStates = data;
    } catch (e) {
      console.warn('failure-state.json unavailable - continuing without recovery state');
    }
    res.json(mergeFailureStates(result, failureStates));

  } catch (e) {

    console.error(
      'GET /api/containers failed',
      e
    );

    res.status(500).json({
      error: 'containers discovery unavailable'
    });
  }
});


// === Routes ===
app.get('/health', (req, res) => res.json({ status: 'ok' }));
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});
app.get('/api/tasks', async (req, res) => {
  try {
    const tasks = await getTasks();
    res.json(tasks);
  } catch (e) {
    console.error('GET /tasks failed', e);
    res.status(500).json({ error: 'internal' });
  }
});
app.post('/api/tasks', async (req, res) => {
  try {
    const task = await createTask(req.body.title);
    res.status(201).json(task);
  } catch (e) {
    console.error('POST /tasks failed', e);
    res.status(500).json({ error: 'internal' });
  }
});
app.patch('/api/tasks/:id', async (req, res) => {
  try {
    const task = await updateTask(req.params.id, req.body.done);
    res.json(task);
  } catch (e) {
    console.error('PATCH /tasks failed', e);
    res.status(500).json({ error: 'internal' });
  }
});
app.delete('/api/tasks/:id', async (req, res) => {
  try {
    const task = await deleteTask(req.params.id);
    if (!task) return res.status(404).json({ error: 'not found' });
    res.status(200).json(task);
  } catch (e) {
    console.error('DELETE /tasks failed', e);
    res.status(500).json({ error: 'internal' });
  }
});
const PORT = process.env.PORT || 3001;
initDb().then(() => {
  app.listen(PORT, () => console.log(`Backend listening on ${PORT}`));
}).catch(err => {
  console.error('DB init failed', err);
  process.exit(1);
});

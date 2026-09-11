// ============================================================
// WebMon - Interface Web
// ============================================================
//
// Ce fichier gere :
// - l'affichage des conteneurs Docker
// - leur etat Docker
// - leur etat fonctionnel
// - l'actualisation automatique du dashboard
// - l'ancienne liste de taches WebMon
//
// ============================================================


// ============================================================
// CONFIGURATION
// ============================================================

const API = '/api';


// ============================================================
// ELEMENTS DE LA PAGE HTML
// ============================================================

// Dashboard Docker
const containersList = document.getElementById('containers-list');
const containerCount = document.getElementById('container-count');

// Ancienne gestion des taches
const list = document.getElementById('list');
const form = document.getElementById('form');
const input = document.getElementById('title');
const emptyState = document.getElementById('empty-state');


// ============================================================
// OUTIL DE SECURITE HTML
// ============================================================

// Empêche qu'un nom de conteneur ou une autre valeur provenant
// de Docker puisse être interprétée comme du code HTML.
function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}


// ============================================================
// ETAT DOCKER
// ============================================================

// Retourne la classe CSS correspondant à l'état Docker.
//
// Exemples :
// running    -> vert
// exited     -> rouge
// restarting -> orange
function getStateClass(state) {

  switch ((state || '').toLowerCase()) {

    case 'running':
      return 'state-running';

    case 'exited':
    case 'dead':
      return 'state-down';

    case 'restarting':
      return 'state-warning';

    case 'paused':
      return 'state-paused';

    default:
      return 'state-unknown';
  }
}


// ============================================================
// ETAT FONCTIONNEL
// ============================================================

// Retourne la classe CSS correspondant à l'état fonctionnel.
function getFunctionalClass(webmon) {

  // Aucun contrôle fonctionnel disponible.
  if (!webmon || !webmon.configured) {
    return 'functional-unconfigured';
  }

  // Un healthcheck Docker existe mais le conteneur
  // est encore en phase de démarrage.
  if (
    webmon.source === 'docker-healthcheck' &&
    webmon.health_status === 'starting'
  ) {
    return 'functional-starting';
  }

  // Le service fonctionne réellement.
  if (webmon.functional) {
    return 'functional-ok';
  }

  // Un contrôle existe mais il échoue.
  return 'functional-critical';
}


// Texte affiché dans le badge fonctionnel.
function getFunctionalText(webmon) {

  if (!webmon || !webmon.configured) {
    return 'Non configuré';
  }

  if (
    webmon.source === 'docker-healthcheck' &&
    webmon.health_status === 'starting'
  ) {
    return 'STARTING';
  }

  return webmon.functional ? 'OK' : 'CRITICAL';
}


// Indique la méthode utilisée par WebMon pour déterminer
// si le service fonctionne réellement.
function getFunctionalSource(webmon) {

  if (!webmon || !webmon.configured) {
    return '';
  }

  if (webmon.source === 'docker-healthcheck') {
    return 'Docker healthcheck';
  }

  if (webmon.source === 'webmon') {
    return 'WebMon heartbeat';
  }

 if (webmon.source === 'auto-http') {
  return 'WebMon HTTP automatique';
  }
  return 'Contrôle WebMon';
}


// ============================================================
// CHARGEMENT DES CONTENEURS DOCKER
// ============================================================

async function loadContainers() {

  try {

    // Demande au backend la liste actuelle des conteneurs.
    //
    // no-store évite que le navigateur affiche une ancienne
    // réponse mise en cache.
    const response = await fetch(`${API}/containers`, {
      cache: 'no-store'
    });

    if (!response.ok) {
      throw new Error(
        `Erreur API /containers : ${response.status}`
      );
    }

    const containers = await response.json();


    // --------------------------------------------------------
    // COMPTEUR DE CONTENEURS
    // --------------------------------------------------------

    if (containerCount) {
      containerCount.textContent =
        `${containers.length} conteneur${containers.length > 1 ? 's' : ''}`;
    }


    // --------------------------------------------------------
    // ZONE D'AFFICHAGE ABSENTE
    // --------------------------------------------------------

    if (!containersList) {
      return;
    }


    // --------------------------------------------------------
    // AUCUN CONTENEUR
    // --------------------------------------------------------

    if (containers.length === 0) {

      containersList.innerHTML =
        '<p>Aucun conteneur Docker détecté.</p>';

      return;
    }


    // --------------------------------------------------------
    // CREATION DES CARTES
    // --------------------------------------------------------

    containersList.innerHTML = containers.map(container => {

      // Informations fonctionnelles ajoutées par le backend.
      const webmon =
        container.webmon || { configured: false };


      // ------------------------------------------------------
      // SOURCE DU CONTROLE FONCTIONNEL
      // ------------------------------------------------------

      let sourceHtml = '';

      if (webmon.configured) {

        sourceHtml = `
          <span class="functional-source">
            Contrôle : ${escapeHtml(getFunctionalSource(webmon))}
          </span>
        `;
      }


      // ------------------------------------------------------
      // HEARTBEAT
      // ------------------------------------------------------

      let heartbeatHtml = '';

      if (
        webmon.source === 'webmon' &&
        typeof webmon.heartbeat_age === 'number' &&
        webmon.heartbeat_age >= 0
      ) {

        heartbeatHtml = `
          <span class="heartbeat-info">
            Heartbeat : ${webmon.heartbeat_age}s
          </span>
        `;
      }


      // ------------------------------------------------------
      // CARTE HTML
      // ------------------------------------------------------

      return `
        <div class="container-card">

          <strong>
            ${escapeHtml(container.Names)}
          </strong>

          <span>
            ${escapeHtml(container.Image)}
          </span>

          <span class="state-badge ${getStateClass(container.State)}">
            ${escapeHtml(container.State || 'unknown')}
          </span>

          <span class="container-status">
            ${escapeHtml(container.Status || '')}
          </span>

          <span class="functional-label">
            Fonctionnel
          </span>

          <span class="functional-badge ${getFunctionalClass(webmon)}">
            ${escapeHtml(getFunctionalText(webmon))}
          </span>

          ${sourceHtml}

          ${heartbeatHtml}

        </div>
      `;

    }).join('');

  } catch (error) {

    console.error(
      'Erreur lors du chargement des conteneurs :',
      error
    );

    if (containerCount) {
      containerCount.textContent = 'Erreur';
    }

    if (containersList) {
      containersList.innerHTML =
        '<p>Impossible de récupérer les conteneurs Docker.</p>';
    }
  }
}


// ============================================================
// ANCIENNE LISTE DE TACHES WEBMON
// ============================================================
//
// On la conserve encore pour ne pas supprimer une partie
// du projet d'origine pendant le développement.
// Elle pourra être retirée plus tard.
// ============================================================

async function loadTasks() {

  if (!list) {
    return;
  }

  try {

    const response = await fetch(`${API}/tasks`, {
      cache: 'no-store'
    });

    if (!response.ok) {
      throw new Error('Impossible de charger les tâches');
    }

    const tasks = await response.json();


    // Des tâches existent.
    if (tasks.length > 0) {

      if (emptyState) {
        emptyState.classList.add('hidden');
      }

      list.innerHTML = tasks.map(task => `

        <li class="${task.done ? 'done' : ''}">

          <label class="task-content">

            <input
              type="checkbox"
              ${task.done ? 'checked' : ''}
              onchange="window.toggleTask(${task.id}, this.checked)"
            >

            <span>
              ${escapeHtml(task.title)}
            </span>

          </label>

          <button
            class="btn-delete"
            onclick="window.deleteTask(${task.id})"
            aria-label="Supprimer"
          >
            ×
          </button>

        </li>

      `).join('');

      return;
    }


    // Aucune tâche.
    list.innerHTML = '';

    if (emptyState) {

      emptyState.classList.remove('hidden');

      emptyState.innerHTML =
        '<p>Aucune tâche en cours.</p>';
    }

  } catch (error) {

    console.error(
      'Erreur lors du chargement des tâches :',
      error
    );

    if (emptyState) {

      emptyState.classList.remove('hidden');

      emptyState.innerHTML =
        '<p>Impossible de charger les tâches.</p>';
    }
  }
}


// ============================================================
// MODIFICATION D'UNE TACHE
// ============================================================

window.toggleTask = async function(id, done) {

  try {

    const response = await fetch(`${API}/tasks/${id}`, {

      method: 'PATCH',

      headers: {
        'Content-Type': 'application/json'
      },

      body: JSON.stringify({
        done
      })
    });

    if (!response.ok) {
      throw new Error('Erreur de modification');
    }

    await loadTasks();

  } catch (error) {

    console.error(
      'Erreur lors de la modification de la tâche :',
      error
    );
  }
};


// ============================================================
// SUPPRESSION D'UNE TACHE
// ============================================================

window.deleteTask = async function(id) {

  try {

    const response = await fetch(`${API}/tasks/${id}`, {
      method: 'DELETE'
    });

    if (!response.ok) {
      throw new Error('Erreur de suppression');
    }

    await loadTasks();

  } catch (error) {

    console.error(
      'Erreur lors de la suppression de la tâche :',
      error
    );
  }
};


// ============================================================
// CREATION D'UNE TACHE
// ============================================================

if (form && input) {

  form.addEventListener('submit', async event => {

    event.preventDefault();

    const title = input.value.trim();

    if (!title) {
      return;
    }

    try {

      const response = await fetch(`${API}/tasks`, {

        method: 'POST',

        headers: {
          'Content-Type': 'application/json'
        },

        body: JSON.stringify({
          title
        })
      });

      if (!response.ok) {
        throw new Error('Erreur de création');
      }

      input.value = '';

      await loadTasks();

    } catch (error) {

      console.error(
        'Erreur lors de la création de la tâche :',
        error
      );
    }
  });
}


// ============================================================
// DEMARRAGE DU DASHBOARD
// ============================================================

// Premier chargement à l'ouverture de la page.
loadTasks();
loadContainers();


// ============================================================
// ACTUALISATION AUTOMATIQUE
// ============================================================

// Recharge les informations Docker toutes les 10 secondes.
setInterval(loadContainers, 10000);


// Quand l'utilisateur revient sur l'onglet WebMon,
// on actualise immédiatement.
//
// Certains navigateurs ralentissent les timers lorsque
// l'onglet reste en arrière-plan.
document.addEventListener('visibilitychange', () => {

  if (!document.hidden) {
    loadContainers();
  }
});

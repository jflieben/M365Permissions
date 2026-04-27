/* M365Permissions — Vanilla JS SPA */
/* Hash-based routing, no build step, no frameworks */

(function () {
    'use strict';

    // ── API Helper ──────────────────────────────────────────────
    const api = {
        async get(url) {
            const res = await fetch(`/api${url}`);
            return res.json();
        },
        async post(url, body) {
            const res = await fetch(`/api${url}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: body ? JSON.stringify(body) : undefined
            });
            return res.json();
        },
        async put(url, body) {
            const res = await fetch(`/api${url}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            return res.json();
        },
        async getBlob(url) {
            return fetch(`/api${url}`);
        }
    };

    // ── Toast Notifications ─────────────────────────────────────
    function showToast(message, type = 'info') {
        const container = document.getElementById('toast-container');
        const toast = document.createElement('div');
        toast.className = `toast ${type}`;
        toast.textContent = message;
        container.appendChild(toast);
        setTimeout(() => toast.remove(), 4000);
    }

    // ── Theme Toggle ────────────────────────────────────────────
    function initTheme() {
        const saved = localStorage.getItem('m365pv2-theme') || 'dark';
        document.documentElement.setAttribute('data-theme', saved);
        updateThemeIcon(saved);

        document.getElementById('themeToggle').addEventListener('click', () => {
            const current = document.documentElement.getAttribute('data-theme');
            const next = current === 'dark' ? 'light' : 'dark';
            document.documentElement.setAttribute('data-theme', next);
            localStorage.setItem('m365pv2-theme', next);
            updateThemeIcon(next);
        });
    }

    function updateThemeIcon(theme) {
        document.getElementById('themeToggle').textContent = theme === 'dark' ? '☀️' : '🌙';
    }

    // ── State ───────────────────────────────────────────────────
    let state = {
        connected: false,
        tenantId: '',
        tenantDomain: '',
        upn: '',
        moduleVersion: '',
        scanRunning: false,
        currentScanId: null,
        refreshTokenExpiry: null
    };

    let pollInterval = null;

    // Build a query string with current tenantId for tenant-scoped API calls
    function tenantQuery(extra) {
        const tid = state.tenantId;
        const params = tid ? `tenantId=${encodeURIComponent(tid)}` : '';
        return extra ? (params ? `${extra}&${params}` : extra) : (params ? `?${params}` : '');
    }

    // ── Status Polling ──────────────────────────────────────────
    async function refreshStatus() {
        try {
            const res = await api.get('/status');
            if (res.success) {
                state.connected = res.data.connected;
                state.tenantId = res.data.tenantId || '';
                state.tenantDomain = res.data.tenantDomain || '';
                state.upn = res.data.userPrincipalName || '';
                state.moduleVersion = res.data.moduleVersion || '';
                state.scanRunning = res.data.scanning || false;
                state.currentScanId = res.data.activeScanId;
                state.refreshTokenExpiry = res.data.refreshTokenExpiry || null;
                updateNavStatus();
            }
        } catch { /* ignore polling errors */ }
    }

    function updateNavStatus() {
        const badge = document.getElementById('connectionStatus');
        const version = document.getElementById('navVersion');
        const disconnectBtn = document.getElementById('disconnectBtn');

        if (state.moduleVersion) version.textContent = `v${state.moduleVersion}`;

        if (state.scanRunning) {
            badge.textContent = 'Scanning...';
            badge.className = 'status-badge scanning';
            if (disconnectBtn) disconnectBtn.style.display = 'none';
        } else if (state.connected) {
            badge.textContent = state.tenantDomain || 'Connected';
            badge.title = state.tenantDomain || '';
            badge.className = 'status-badge connected';
            if (disconnectBtn) disconnectBtn.style.display = '';
        } else {
            badge.textContent = 'Disconnected';
            badge.className = 'status-badge disconnected';
            if (disconnectBtn) disconnectBtn.style.display = 'none';
        }
    }

    // ── Router ──────────────────────────────────────────────────
    const routes = {
        '/': renderDashboard,
        '/scan': renderScan,
        '/results': renderResults,
        '/compare': renderCompare,
        '/settings': renderSettings,
        '/user-lookup': renderUserLookup,
        '/trends': renderTrends,
        '/audit': renderAudit,
        '/policies': renderPolicies
    };

    function navigate() {
        const hash = window.location.hash.slice(1) || '/';
        const path = hash.split('?')[0];
        const render = routes[path] || renderDashboard;

        document.querySelectorAll('.nav-link').forEach(link => {
            const page = link.getAttribute('data-page');
            const isActive =
                (path === '/' && page === 'dashboard') ||
                path === `/${page}`;
            link.classList.toggle('active', isActive);
        });

        render();
    }

    // ── Modal / Overlay Helpers ─────────────────────────────────
    function showModal(title, contentHtml) {
        let overlay = document.getElementById('modalOverlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.id = 'modalOverlay';
            overlay.className = 'modal-overlay';
            document.body.appendChild(overlay);
        }
        overlay.innerHTML = `
            <div class="modal-content">
                <div class="modal-header">
                    <h3>${escapeHtml(title)}</h3>
                    <button class="btn-icon modal-close" onclick="document.getElementById('modalOverlay').style.display='none'">✕</button>
                </div>
                <div class="modal-body">${contentHtml}</div>
            </div>
        `;
        overlay.style.display = 'flex';
        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) overlay.style.display = 'none';
        });
    }

    function closeModal() {
        const overlay = document.getElementById('modalOverlay');
        if (overlay) overlay.style.display = 'none';
    }

    // ── Remediation Links ───────────────────────────────────────
    function getRemediationLink(entry) {
        const cat = (entry.category || '').toLowerCase();
        if (cat === 'sharepoint' || cat === 'onedrive') {
            return { label: 'SharePoint Admin Center', url: `https://${state.tenantDomain?.split('.')[0] || 'tenant'}-admin.sharepoint.com/_layouts/15/online/AdminHome.aspx#/siteManagement` };
        }
        if (cat === 'entra') {
            if ((entry.principalRole || '').toLowerCase().includes('admin')) {
                return { label: 'Entra ID Roles', url: 'https://entra.microsoft.com/#view/Microsoft_AAD_IAM/RolesManagementMenuBlade/~/AllRoles' };
            }
            if ((entry.targetType || '').toLowerCase().includes('application')) {
                return { label: 'Entra App Registrations', url: 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade/quickStartType~/null/sourceType/Microsoft_AAD_IAM' };
            }
            return { label: 'Entra Admin Center', url: 'https://entra.microsoft.com/' };
        }
        if (cat === 'exchange') {
            return { label: 'Exchange Admin Center', url: 'https://admin.exchange.microsoft.com/#/mailboxes' };
        }
        if (cat === 'powerbi') {
            return { label: 'Power BI Admin Portal', url: 'https://app.powerbi.com/admin-portal' };
        }
        if (cat === 'powerautomate') {
            return { label: 'Power Automate Admin', url: 'https://admin.powerplatform.microsoft.com/environments' };
        }
        if (cat === 'azure') {
            return { label: 'Azure Portal', url: 'https://portal.azure.com/#view/Microsoft_Azure_PIMCommon/CommonMenuBlade/~/quickStart' };
        }
        return null;
    }

    // ── Detail Panel ────────────────────────────────────────────
    function showDetailPanel(entry) {
        const fields = [
            ['Risk Level', entry.riskLevel],
            ['Risk Reason', entry.riskReason],
            ['Category', entry.category],
            ['Target Path', entry.targetPath],
            ['Target Type', entry.targetType],
            ['Target ID', entry.targetId],
            ['Principal UPN', entry.principalEntraUpn],
            ['Principal Name', entry.principalSysName],
            ['Principal Entra ID', entry.principalEntraId],
            ['Principal System ID', entry.principalSysId],
            ['Principal Type', entry.principalType],
            ['Role', entry.principalRole],
            ['Through', entry.through],
            ['Access Type', entry.accessType],
            ['Tenure', entry.tenure],
            ['Parent ID', entry.parentId],
            ['Start Date', entry.startDateTime],
            ['End Date', entry.endDateTime],
            ['Created', entry.createdDateTime],
            ['Modified', entry.modifiedDateTime]
        ];

        const isGroup = entry.principalType === 'SecurityGroup' || entry.principalType === 'M365Group' ||
                         entry.targetType === 'SecurityGroup' || entry.targetType === 'M365Group';
        const groupHint = isGroup ? `<div style="margin-top:12px">
            <button class="btn btn-secondary" style="padding:6px 14px;font-size:0.85em"
                onclick="window.m365.showGroupMembers(${entry.scanId || 'null'}, '${escapeAttr(entry.targetId)}', '${escapeAttr(entry.targetPath || entry.principalSysName)}')">
                👥 View Group Members
            </button>
        </div>` : '';

        const remediation = getRemediationLink(entry);
        const remediationHtml = remediation ? `<div style="margin-top:12px">
            <a href="${escapeAttr(remediation.url)}" target="_blank" rel="noopener" class="btn btn-secondary" style="padding:6px 14px;font-size:0.85em;text-decoration:none">
                🔧 Open in ${escapeHtml(remediation.label)}
            </a>
        </div>` : '';

        showModal('Permission Details', `
            <table class="detail-table">
                ${fields.filter(([,v]) => v).map(([k, v]) => `<tr><td class="detail-label">${escapeHtml(k)}</td><td>${escapeHtml(v)}</td></tr>`).join('')}
            </table>
            ${groupHint}
            ${remediationHtml}
        `);
    }

    // ── Group Members Popup ─────────────────────────────────────
    async function showGroupMembers(scanId, groupId, groupName) {
        if (!scanId || !groupId) { showToast('No scan data available for group lookup', 'error'); return; }
        showModal(`Members of ${groupName}`, '<div class="empty-state"><p>Loading...</p></div>');
        try {
            const res = await api.get(`/scans/${scanId}/group-members?groupId=${encodeURIComponent(groupId)}`);
            if (!res.success || !res.data) {
                showModal(`Members of ${groupName}`, '<div class="empty-state"><p>No members found</p></div>');
                return;
            }
            const members = res.data;
            if (members.length === 0) {
                showModal(`Members of ${groupName}`, '<div class="empty-state"><p>No members found in scan data</p></div>');
                return;
            }
            showModal(`Members of ${groupName} (${members.length})`, `
                <table>
                    <thead><tr><th>Name</th><th>UPN</th><th>Type</th><th>Entra ID</th></tr></thead>
                    <tbody>${members.map(m => `<tr>
                        <td>${escapeHtml(m.principalSysName || '')}</td>
                        <td>${escapeHtml(m.principalEntraUpn || '')}</td>
                        <td>${escapeHtml(m.principalType || '')}</td>
                        <td style="font-size:0.8em;color:var(--text-muted)">${escapeHtml(m.principalEntraId || '')}</td>
                    </tr>`).join('')}</tbody>
                </table>
            `);
        } catch (e) {
            showModal(`Members of ${groupName}`, `<p>Error loading members: ${escapeHtml(e.message)}</p>`);
        }
    }

    // ── Sortable/Filterable Table Builder ───────────────────────
    let tableState = {
        sortColumn: null,
        sortDirection: 'asc',
        columnFilters: {},
        filterOptions: {}
    };

    function resetTableState() {
        tableState = { sortColumn: null, sortDirection: 'asc', columnFilters: {}, filterOptions: {} };
    }

    const dropdownFilterColumns = new Set(['category', 'targetType', 'principalType', 'through', 'accessType', 'tenure', 'riskLevel']);
    const columnDbMap = {
        category: 'category', targetPath: 'target_path', targetType: 'target_type',
        principal: 'principal_entra_upn', principalRole: 'principal_role',
        through: 'through', accessType: 'access_type', tenure: 'tenure',
        principalType: 'principal_type', riskLevel: 'risk_level'
    };

    function buildSortableHeader(columns, onSort) {
        return `<thead><tr>${columns.map(col => {
            const isSorted = tableState.sortColumn === col.db;
            const arrow = isSorted ? (tableState.sortDirection === 'asc' ? ' ↑' : ' ↓') : '';
            const filterHtml = col.filterable ? buildFilterControl(col) : '';
            return `<th>
                <div class="th-content" style="cursor:pointer" data-sort="${col.db}">
                    <span class="th-label">${escapeHtml(col.label)}${arrow}</span>
                </div>
                ${filterHtml}
            </th>`;
        }).join('')}</tr></thead>`;
    }

    function buildFilterControl(col) {
        if (dropdownFilterColumns.has(col.key)) {
            const options = tableState.filterOptions[col.db] || [];
            const selected = (tableState.columnFilters[col.db] || '').split('|').filter(Boolean);
            const selectedSet = new Set(selected);
            if (options.length === 0) return '';
            return `<div class="th-filter">
                <select class="filter-select" data-filter-col="${col.db}" multiple size="1"
                    title="${selected.length ? selected.join(', ') : 'All'}">
                    ${options.map(o => `<option value="${escapeAttr(o)}" ${selectedSet.has(o) ? 'selected' : ''}>${escapeHtml(o)}</option>`).join('')}
                </select>
            </div>`;
        }
        const val = tableState.columnFilters[col.db] || '';
        return `<div class="th-filter">
            <input type="text" class="filter-input" data-filter-col="${col.db}"
                placeholder="Filter..." value="${escapeAttr(val)}">
        </div>`;
    }

    function attachTableListeners(tableEl, onSort, onFilter) {
        tableEl.querySelectorAll('.th-content[data-sort]').forEach(th => {
            th.addEventListener('click', () => {
                const col = th.dataset.sort;
                if (tableState.sortColumn === col) {
                    tableState.sortDirection = tableState.sortDirection === 'asc' ? 'desc' : 'asc';
                } else {
                    tableState.sortColumn = col;
                    tableState.sortDirection = 'asc';
                }
                onSort();
            });
        });

        tableEl.querySelectorAll('.filter-input').forEach(input => {
            input.addEventListener('input', debounce(() => {
                const col = input.dataset.filterCol;
                tableState.columnFilters[col] = input.value;
                onFilter();
            }, 400));
        });

        tableEl.querySelectorAll('.filter-select').forEach(sel => {
            sel.addEventListener('change', () => {
                const col = sel.dataset.filterCol;
                const selected = Array.from(sel.selectedOptions).map(o => o.value);
                tableState.columnFilters[col] = selected.join('|');
                sel.title = selected.length ? selected.join(', ') : 'All';
                onFilter();
            });
        });
    }

    // ── Quick Filter Presets ────────────────────────────────────
    async function applyQuickFilter(preset) {
        resetTableState();
        // Toggle active state on quick filter pills
        document.querySelectorAll('#quickFilters .btn-active').forEach(b => b.classList.remove('btn-active'));
        const btn = event && event.target ? event.target : null;
        if (btn) btn.classList.add('btn-active');

        switch (preset) {
            case 'critical-high':
                tableState.columnFilters['risk_level'] = 'Critical|High';
                break;
            case 'external':
                tableState.columnFilters['principal_type'] = 'Guest';
                break;
            case 'anonymous':
                tableState.columnFilters['through'] = 'AnonymousLink';
                break;
            case 'admin-roles':
                tableState.columnFilters['category'] = 'Entra';
                break;
            case 'full-access':
                tableState.columnFilters['principal_role'] = 'FullAccess';
                break;
        }
        currentPage = 1;
        await loadFilterOptions();
        await loadResults();
    }

    // ── Pages ───────────────────────────────────────────────────

    // Dashboard
    async function renderDashboard() {
        const app = document.getElementById('app');
        app.innerHTML = `
            <div class="card">
                <h2>Dashboard</h2>
                <div class="stats-grid" id="dashStats">
                    <div class="stat-card">
                        <div class="stat-value" id="statTenant">—</div>
                        <div class="stat-label">Tenant</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value" id="statScans">—</div>
                        <div class="stat-label">Completed Scans</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value" id="statPerms">—</div>
                        <div class="stat-label">Total Permissions</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value" id="statStatus">—</div>
                        <div class="stat-label">Status</div>
                    </div>
                    <div class="stat-card" id="tokenExpiryCard" style="display:none">
                        <div class="stat-value" id="statTokenExpiry" style="font-size:1.2em">—</div>
                        <div class="stat-label">Token Expires</div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-value" id="statDbSize">—</div>
                        <div class="stat-label">Database Size</div>
                    </div>
                </div>
                <div class="btn-group">
                    ${state.connected
                        ? `<button class="btn btn-primary" onclick="window.m365.startQuickScan()">▶ Start Scan</button>
                           <button class="btn btn-secondary" onclick="location.hash='#/user-lookup'">🔍 User Lookup</button>
                           <button class="btn btn-secondary" onclick="window.m365.disconnect()" title="Disconnect and connect to a different tenant">⏏ Switch Tenant</button>`
                        : '<button class="btn btn-primary" onclick="window.m365.connect()">🔗 Connect</button>'
                    }
                </div>
            </div>
            <div class="card" id="riskSummaryCard" style="display:none">
                <h2>Risk Overview (Latest Scan)</h2>
                <div class="stats-grid" id="riskStats"></div>
            </div>
            <div class="card" id="deltaCard" style="display:none">
                <h2>Changes Since Previous Scan</h2>
                <div class="stats-grid" id="deltaStats"></div>
                <div style="margin-top:8px">
                    <a id="deltaCompareLink" href="#/compare" class="btn btn-secondary" style="padding:6px 14px;font-size:0.85em;text-decoration:none">View Full Comparison</a>
                </div>
            </div>
            <div class="card" id="recentScansCard" style="display:none">
                <h2>Recent Scans</h2>
                <div class="table-wrapper">
                    <table><thead><tr>
                        <th>ID</th><th>Tenant</th><th>Date</th><th>Types</th><th>Status</th><th>Permissions</th><th>Notes</th><th>Actions</th>
                    </tr></thead><tbody id="recentScansBody"></tbody></table>
                </div>
            </div>
        `;

        document.getElementById('statTenant').textContent = state.tenantDomain || '—';
        document.getElementById('statStatus').textContent = state.connected ? '✓ Connected' : '✗ Not connected';
        document.getElementById('statStatus').style.fontSize = '1.3em';

        if (state.refreshTokenExpiry) {
            const expiryCard = document.getElementById('tokenExpiryCard');
            const expiryVal = document.getElementById('statTokenExpiry');
            if (expiryCard && expiryVal) {
                expiryCard.style.display = '';
                const exp = new Date(state.refreshTokenExpiry);
                const now = new Date();
                const daysLeft = Math.ceil((exp - now) / (1000 * 60 * 60 * 24));
                expiryVal.textContent = daysLeft > 0 ? `${daysLeft} days` : 'Expired';
                expiryVal.style.color = daysLeft <= 7 ? 'var(--error)' : daysLeft <= 14 ? 'var(--warning)' : 'var(--success)';
            }
        }

        // Load database size for dashboard
        try {
            const dbRes = await api.get('/database');
            if (dbRes.success) {
                document.getElementById('statDbSize').textContent = dbRes.data.sizeMB + ' MB';
            }
        } catch { /* best effort */ }

        try {
            const scans = await api.get('/scans' + tenantQuery());
            if (scans.success && scans.data.length > 0) {
                const completedScans = scans.data.filter(s => s.status === 'Completed');
                document.getElementById('statScans').textContent = completedScans.length;
                const totalPerms = completedScans.reduce((sum, s) => sum + (s.totalPermissions || 0), 0);
                document.getElementById('statPerms').textContent = totalPerms.toLocaleString();
                document.getElementById('recentScansCard').style.display = '';

                const tbody = document.getElementById('recentScansBody');
                tbody.innerHTML = scans.data.slice(0, 10).map(s => `<tr>
                    <td>${s.id}</td>
                    <td title="${escapeAttr(s.tenantDomain || '')}" style="max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${escapeHtml(s.tenantDomain || '—')}</td>
                    <td>${new Date(s.startedAt).toLocaleString()}</td>
                    <td>${escapeHtml(s.scanTypes || '')}</td>
                    <td><span style="color:${s.status === 'Completed' ? 'var(--success)' : s.status === 'Failed' ? 'var(--error)' : 'var(--text-muted)'}">${s.status}</span></td>
                    <td>${s.totalPermissions ? s.totalPermissions.toLocaleString() : '—'}</td>
                    <td>
                        <span class="scan-notes-text" id="scanNotes${s.id}" title="Click to edit"
                            onclick="window.m365.editScanNotes(${s.id})"
                            style="cursor:pointer;max-width:150px;display:inline-block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text-muted);font-size:0.85em">
                            ${escapeHtml(s.notes || s.tags || '—')}
                        </span>
                    </td>
                    <td>
                        <button class="btn btn-secondary" style="padding:4px 10px;font-size:0.8em"
                            onclick="location.hash='#/results?id=${s.id}'">View</button>
                    </td>
                </tr>`).join('');

                // Risk summary for latest completed scan
                if (completedScans.length > 0) {
                    const latestId = completedScans[0].id;
                    try {
                        const riskRes = await api.get(`/scans/${latestId}/risk-summary`);
                        if (riskRes.success && riskRes.data) {
                            const riskCard = document.getElementById('riskSummaryCard');
                            riskCard.style.display = '';
                            const riskData = riskRes.data;
                            const levels = ['Critical', 'High', 'Medium', 'Low', 'Info'];
                            const colors = { Critical: '#b71c1c', High: '#f44336', Medium: '#ff9800', Low: '#4caf50', Info: '#2196f3' };
                            document.getElementById('riskStats').innerHTML = levels.map(l => {
                                const count = riskData[l] || 0;
                                return `<div class="stat-card" style="cursor:pointer" onclick="location.hash='#/results?id=${latestId}';setTimeout(()=>window.m365.applyQuickFilter('${l.toLowerCase() === 'critical' || l.toLowerCase() === 'high' ? 'critical-high' : ''}'),300)">
                                    <div class="stat-value" style="color:${colors[l]}">${count.toLocaleString()}</div>
                                    <div class="stat-label">${l}</div>
                                </div>`;
                            }).join('');
                        }
                    } catch { }

                    // Auto-compare with previous scan (already tenant-scoped by API)
                    if (completedScans.length >= 2) {
                        try {
                            const newId = completedScans[0].id;
                            const oldId = completedScans[1].id;
                            const cmpRes = await api.post('/compare', { oldScanId: oldId, newScanId: newId });
                            if (cmpRes.success && cmpRes.data) {
                                const r = cmpRes.data;
                                const addedCount = (r.added || []).length;
                                const removedCount = (r.removed || []).length;
                                const changedCount = (r.changed || []).length;
                                if (addedCount > 0 || removedCount > 0 || changedCount > 0) {
                                    document.getElementById('deltaCard').style.display = '';
                                    document.getElementById('deltaStats').innerHTML = `
                                        <div class="stat-card"><div class="stat-value" style="color:var(--success)">+${addedCount}</div><div class="stat-label">Added</div></div>
                                        <div class="stat-card"><div class="stat-value" style="color:var(--error)">-${removedCount}</div><div class="stat-label">Removed</div></div>
                                        <div class="stat-card"><div class="stat-value" style="color:var(--warning)">~${changedCount}</div><div class="stat-label">Changed</div></div>
                                    `;
                                }
                            }
                        } catch { }
                    }
                }
            }
        } catch { }
    }

    // Scan
    async function renderScan() {
        const app = document.getElementById('app');
        const isScanning = state.scanRunning;

        const scanCategories = [
            {
                val: 'SharePoint',
                icon: '📁',
                label: 'SharePoint Online',
                checked: true,
                scans: [
                    'Site collection administrators',
                    'Site / library / list role assignments',
                    'Graph site permissions (app-only grants)',
                    'Sharing links and anonymous access',
                ],
                notScanned: [
                    'Individual file/item-level permissions',
                    'Sensitivity labels on sites',
                ],
            },
            {
                val: 'Entra',
                icon: '🔐',
                label: 'Entra ID',
                checked: true,
                scans: [
                    'Directory role assignments (active & PIM-eligible)',
                    'App registrations and their API permissions',
                    'OAuth2 permission grants (admin & user consent)',
                    'Group memberships and ownership',
                ],
                notScanned: [
                    'Conditional Access policies',
                    'Administrative units',
                ],
            },
            {
                val: 'Exchange',
                icon: '📧',
                label: 'Exchange Online',
                checked: true,
                scans: [
                    'Mailbox Full Access delegates',
                    'Send As / Send on Behalf permissions',
                ],
                notScanned: [
                    'Individual folder-level permissions',
                    'Transport rules and mail flow',
                ],
            },
            {
                val: 'OneDrive',
                icon: '☁️',
                label: 'OneDrive for Business',
                checked: false,
                scans: [
                    'OneDrive site administrators',
                    'Sharing permissions on personal sites',
                    'External sharing configuration',
                    'Only active user sites'
                ],
                notScanned: [
                    'Individual file/folder-level sharing',
                    'Sync client configurations',
                    'Inactive or deleted user sites'
                ],
            },
            {
                val: 'PowerBI',
                icon: '📊',
                label: 'Power BI',
                checked: false,
                scans: [
                    'Workspace role assignments (Admin, Member, Contributor, Viewer)',
                    'Workspace ownership',
                ],
                notScanned: [
                    'Report-level row-level security (RLS)',
                    'Dataflow connections',
                ],
            },
            {
                val: 'PowerAutomate',
                icon: '⚡',
                label: 'Power Platform',
                checked: false,
                scans: [
                    'Environment role assignments',
                    'Power Automate flow ownership and sharing',
                    'Power Apps ownership and sharing',
                    'Custom connector permissions',
                ],
                notScanned: [
                    'Connection reference credentials',
                    'Dataverse table-level security',
                ],
            },
            {
                val: 'Azure',
                icon: '🌐',
                label: 'Azure RBAC',
                checked: false,
                scans: [
                    'Subscription-level role assignments',
                    'Resource group-level role assignments',
                    'Classic administrator roles',
                ],
                notScanned: [
                    'Resource-level role assignments',
                    'Azure Policy assignments',
                    'Management group roles',
                ],
            },
            {
                val: 'AzureDevOps',
                icon: '🔧',
                label: 'Azure DevOps',
                checked: false,
                scans: [
                    'Organization membership enumeration',
                    'Project-level security group memberships',
                    'Organization-level group memberships (Project Collection Administrators, etc.)',
                    'Team membership resolution',
                ],
                notScanned: [
                    'Repository-level permissions (branch policies, etc.)',
                    'Pipeline permissions and service connections',
                    'Area / iteration path security',
                ],
            },
            {
                val: 'Purview',
                icon: '🛡️',
                label: 'Purview Compliance',
                checked: false,
                scans: [
                    'Compliance Center role groups (Get-RoleGroup)',
                    'Role group members (Get-RoleGroupMember)',
                    'Built-in and custom compliance role groups',
                ],
                notScanned: [
                    'Sensitivity label policies and assignments',
                    'Data Loss Prevention (DLP) policies',
                    'Retention policies and labels',
                    'eDiscovery case-level permissions',
                ],
            },
        ];

        app.innerHTML = `
            <div class="card" ${isScanning ? 'style="display:none"' : ''}>
                <h2>Permission Scan</h2>
                ${!state.connected ? `
                    <div class="empty-state">
                        <div class="emoji">🔌</div>
                        <p>Connect to Microsoft 365 first</p>
                        <button class="btn btn-primary" style="margin-top:16px" onclick="window.m365.connect()">Connect</button>
                    </div>
                ` : `
                    <div class="form-group">
                        <p style="color:var(--text-muted);margin-bottom:16px;font-size:0.9em">Select which Microsoft 365 services to scan for permissions. Hover over a category for details.</p>
                        <div class="scan-cat-grid" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px">
                            ${scanCategories.map(t => `
                                <label class="scan-cat-card" style="display:flex;flex-direction:column;padding:16px;background:var(--bg-input);border:2px solid ${t.checked ? 'var(--accent)' : 'var(--border)'};border-radius:12px;cursor:pointer;transition:all 0.15s;user-select:none;position:relative">
                                    <div style="display:flex;align-items:center;gap:10px;margin-bottom:10px">
                                        <input type="checkbox" value="${t.val}" ${t.checked ? 'checked' : ''} style="width:18px;height:18px;accent-color:var(--accent);flex-shrink:0"
                                            onchange="this.closest('.scan-cat-card').style.borderColor=this.checked?'var(--accent)':'var(--border)';this.closest('.scan-cat-card').style.background=this.checked?'var(--bg-card)':'var(--bg-input)'">
                                        <span style="font-size:1.5em;flex-shrink:0">${t.icon}</span>
                                        <span style="font-weight:700;font-size:1.05em">${t.label}</span>
                                    </div>
                                    <div style="font-size:0.8em;line-height:1.5;flex:1">
                                        <div style="color:var(--text-muted);margin-bottom:6px;font-weight:600">✅ What is scanned:</div>
                                        <ul style="margin:0 0 8px 16px;padding:0;color:var(--text-secondary)">
                                            ${t.scans.map(s => `<li>${s}</li>`).join('')}
                                        </ul>
                                        <div style="color:var(--text-muted);margin-bottom:4px;font-weight:600">🚫 Not included:</div>
                                        <ul style="margin:0 0 0 16px;padding:0;color:var(--text-muted);font-style:italic">
                                            ${t.notScanned.map(s => `<li>${s}</li>`).join('')}
                                        </ul>
                                    </div>
                                </label>
                            `).join('')}
                        </div>
                        <div style="margin-top:10px;display:flex;gap:8px">
                            <button type="button" class="btn btn-secondary" style="padding:3px 10px;font-size:0.78em"
                                onclick="document.querySelectorAll('.scan-cat-card input').forEach(c=>{c.checked=true;c.dispatchEvent(new Event('change'))})">Select All</button>
                            <button type="button" class="btn btn-secondary" style="padding:3px 10px;font-size:0.78em"
                                onclick="document.querySelectorAll('.scan-cat-card input').forEach(c=>{c.checked=false;c.dispatchEvent(new Event('change'))})">Clear All</button>
                        </div>
                    </div>
                    <div style="margin:16px 0;padding:14px 16px;background:var(--bg-input);border:1px solid var(--border);border-radius:10px;font-size:0.85em;line-height:1.6">
                        <strong>💡 Need deeper scanning?</strong><br>
                        <a href="https://m365permissions.com" target="_blank" rel="noopener" style="color:var(--accent);text-decoration:underline">M365Permissions.com</a>
                        offers additional scanning depth including item-level SharePoint, Teams &amp; OneDrive permissions,
                        Exchange folder-level permissions, security roles at any level, and automated scheduled scans, historical tracking and actionable built in reports.
                    </div>
                    <div id="precheckResults" style="display:none;margin-bottom:12px"></div>
                    <div class="btn-group">
                        <button class="btn btn-secondary" id="btnPrecheck" onclick="window.m365.precheckScan()">🔍 Pre-check Permissions</button>
                        <button class="btn btn-primary" id="btnStartScan" onclick="window.m365.startScan()">▶ Start Scan</button>
                    </div>
                `}
            </div>
            <div class="card" id="progressCard" style="${isScanning ? '' : 'display:none'}">
                <h2>Scan Progress</h2>
                <div class="btn-group" style="margin-bottom:12px">
                    <button class="btn btn-danger" id="btnCancelScan2" onclick="window.m365.cancelScan()">⏹ Cancel Scan</button>
                </div>
                <div class="progress-bar"><div class="progress-fill" id="progressFill" style="width:0%"></div></div>
                <p id="progressText" style="font-size:0.9em;color:var(--text-muted);margin:8px 0">Preparing...</p>
                <div id="categoryProgress" style="margin:12px 0"></div>
                <div id="throttleStatus" style="display:none;margin:8px 0;padding:8px 12px;background:var(--bg-input);border-radius:6px;font-size:0.8em;color:var(--text-muted)"></div>
                <div class="log-container" id="scanLog"></div>
            </div>
        `;

        if (state.scanRunning) {
            startProgressPolling();
        }
    }

    function startProgressPolling() {
        const progressCard = document.getElementById('progressCard');
        const setupCard = progressCard?.previousElementSibling;

        if (progressCard) progressCard.style.display = '';
        if (setupCard) setupCard.style.display = 'none';

        if (pollInterval) clearInterval(pollInterval);
        pollInterval = setInterval(async () => {
            try {
                const res = await api.get('/scan/progress');
                if (!res.success || !res.data) return;

                const p = res.data;
                const fill = document.getElementById('progressFill');
                const text = document.getElementById('progressText');
                const log = document.getElementById('scanLog');
                const catProg = document.getElementById('categoryProgress');

                const pct = Math.min(100, Math.round(p.overallPercent || 0));
                if (fill) fill.style.width = `${pct}%`;

                const statusText = p.overallStatus === 'Completed' ? '100% — Scan complete!'
                    : p.overallStatus === 'Failed' ? 'Scan failed'
                    : p.overallStatus === 'Cancelled' ? 'Scan cancelled'
                    : `${pct}%`;
                if (text) text.textContent = statusText;

                if (catProg && p.categories && p.categories.length > 0) {
                    catProg.innerHTML = p.categories.map(c => {
                        const catPct = Math.min(100, c.percentComplete || 0);
                        const icon = c.status === 'Completed' ? '✓' : c.status === 'Running' ? '⏳' : c.status === 'Pending' ? '⏸' : '✗';
                        return `<div style="display:flex;align-items:center;gap:8px;margin:4px 0;font-size:0.85em">
                            <span>${icon}</span>
                            <span style="min-width:100px;font-weight:600">${escapeHtml(c.category)}</span>
                            <div style="flex:1;height:6px;background:var(--bg-input);border-radius:3px;overflow:hidden">
                                <div style="height:100%;width:${catPct}%;background:${c.status === 'Completed' ? 'var(--success)' : 'var(--accent)'};border-radius:3px;transition:width 0.5s"></div>
                            </div>
                            <span style="min-width:40px;text-align:right;color:var(--text-muted)">${Math.round(catPct)}%</span>
                            <span style="min-width:80px;color:var(--text-muted);font-size:0.9em">${c.permissionsFound || 0} found</span>
                        </div>`;
                    }).join('');
                }

                if (log && p.recentLogs && p.recentLogs.length > 0) {
                    log.innerHTML = p.recentLogs
                        .map(l => `<div class="log-entry">${escapeHtml(l)}</div>`)
                        .join('');
                    log.scrollTop = log.scrollHeight;
                }

                // Poll throttle metrics
                try {
                    const tRes = await api.get('/scan/throttle');
                    const tDiv = document.getElementById('throttleStatus');
                    if (tRes.success && tRes.data && tDiv) {
                        const t = tRes.data;
                        tDiv.style.display = '';
                        tDiv.innerHTML = `⚡ Throttle: ${t.currentConcurrency}/${t.maxConcurrency} concurrent | ${t.totalRequests} requests | ${t.throttledRequests} throttled | ${t.requestsPerSecond?.toFixed(1) || 0}/s`;
                    }
                } catch { }

                const done = p.overallStatus === 'Completed' || p.overallStatus === 'Failed' || p.overallStatus === 'Cancelled';
                if (done) {
                    clearInterval(pollInterval);
                    pollInterval = null;
                    state.scanRunning = false;
                    updateNavStatus();
                    const btnCancel2 = document.getElementById('btnCancelScan2');
                    if (btnCancel2) btnCancel2.style.display = 'none';
                    if (p.overallStatus === 'Completed' && fill) fill.style.width = '100%';

                    // Show completion actions in the progress card
                    const progressCard = document.getElementById('progressCard');
                    if (progressCard) {
                        const actionsDiv = document.createElement('div');
                        actionsDiv.className = 'btn-group';
                        actionsDiv.style.marginTop = '16px';
                        if (p.overallStatus === 'Completed' && p.scanId) {
                            actionsDiv.innerHTML = `
                                <a class="btn btn-primary" href="#/results?id=${p.scanId}">📋 View Results</a>
                                <button class="btn btn-secondary" onclick="location.hash='#/scan';window.m365.route()">🔄 New Scan</button>
                            `;
                        } else {
                            actionsDiv.innerHTML = `
                                <button class="btn btn-secondary" onclick="location.hash='#/scan';window.m365.route()">🔄 New Scan</button>
                            `;
                        }
                        progressCard.appendChild(actionsDiv);
                    }

                    showToast(p.overallStatus === 'Completed' ? 'Scan completed!' : p.overallStatus === 'Failed' ? 'Scan failed' : 'Scan cancelled',
                        p.overallStatus === 'Completed' ? 'success' : 'error');
                }
            } catch { }
        }, 2000);
    }

    // Results
    let currentPage = 1;
    const pageSize = 50;
    let currentScanIdForResults = null;
    let hiddenColumns = new Set(JSON.parse(localStorage.getItem('m365pv2-hiddenCols') || '[]'));

    async function renderResults() {
        resetTableState();
        const app = document.getElementById('app');
        const params = new URLSearchParams(window.location.hash.split('?')[1] || '');
        const scanId = params.get('id');

        app.innerHTML = `
            <div class="card">
                <h2>Scan Results</h2>
                <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px" id="quickFilters">
                    <button class="btn btn-secondary" style="padding:4px 10px;font-size:0.8em" onclick="window.m365.applyQuickFilter('critical-high')">🔴 Critical/High</button>
                    <button class="btn btn-secondary" style="padding:4px 10px;font-size:0.8em" onclick="window.m365.applyQuickFilter('external')">👤 External Users</button>
                    <button class="btn btn-secondary" style="padding:4px 10px;font-size:0.8em" onclick="window.m365.applyQuickFilter('anonymous')">🔗 Anonymous Links</button>
                    <button class="btn btn-secondary" style="padding:4px 10px;font-size:0.8em" onclick="window.m365.applyQuickFilter('admin-roles')">🛡️ Admin Roles</button>
                    <button class="btn btn-secondary" style="padding:4px 10px;font-size:0.8em" onclick="window.m365.applyQuickFilter('full-access')">📬 Full Access</button>
                    <button class="btn btn-secondary" style="padding:4px 10px;font-size:0.8em" onclick="window.m365.clearFilters()">✕ Clear</button>
                </div>
                <div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px;align-items:flex-end">
                    <div class="form-group" style="margin:0;min-width:250px">
                        <label>Scan</label>
                        <select id="scanSelect" style="padding:8px;background:var(--bg-input);border:1px solid var(--border);border-radius:8px;color:var(--text);width:100%"></select>
                    </div>
                    <div class="form-group" style="margin:0;min-width:150px">
                        <label>Category</label>
                        <select id="categoryFilter" style="padding:8px;background:var(--bg-input);border:1px solid var(--border);border-radius:8px;color:var(--text)">
                            <option value="">All Categories</option>
                        </select>
                    </div>
                    <div class="form-group" style="margin:0;flex:1;min-width:200px">
                        <label>Search</label>
                        <input id="searchInput" type="text" placeholder="Search targets, principals, roles..." style="padding:8px;background:var(--bg-input);border:1px solid var(--border);border-radius:8px;color:var(--text);width:100%">
                    </div>
                    <button class="btn btn-secondary" onclick="window.m365.exportResults()">📥 Export</button>
                    <button class="btn btn-secondary" onclick="window.m365.toggleColumnPicker()" title="Show/hide columns">📊 Columns</button>
                </div>
                <div id="columnPicker" style="display:none;margin-bottom:12px;padding:8px 12px;background:var(--bg-input);border-radius:8px;font-size:0.85em"></div>
                <div class="table-wrapper" id="resultsTable">
                    <div class="empty-state"><div class="emoji">📋</div><p>Select a scan to view results</p></div>
                </div>
                <div class="pagination" id="pagination"></div>
            </div>
        `;

        try {
            const scans = await api.get('/scans' + tenantQuery());
            if (scans.success && scans.data.length > 0) {
                const sel = document.getElementById('scanSelect');
                sel.innerHTML = '<option value="">— Select a scan —</option>' + scans.data.map(s =>
                    `<option value="${s.id}" ${s.id == scanId ? 'selected' : ''}>Scan #${s.id} — ${s.tenantDomain ? s.tenantDomain + ' — ' : ''}${new Date(s.startedAt).toLocaleDateString()} — ${s.scanTypes} (${s.status})</option>`
                ).join('');

                sel.addEventListener('change', () => { resetTableState(); loadCategories(); loadFilterOptions(); loadResults(); });
                document.getElementById('categoryFilter').addEventListener('change', () => { currentPage = 1; loadFilterOptions(); loadResults(); });
                document.getElementById('searchInput').addEventListener('input', debounce(() => { currentPage = 1; loadResults(); }, 400));

                if (scanId || sel.value) {
                    if (scanId) sel.value = scanId;
                    loadCategories();
                    loadFilterOptions();
                    loadResults();
                }
            } else {
                document.getElementById('resultsTable').innerHTML = '<div class="empty-state"><div class="emoji">📋</div><p>No scans found. Run a scan first.</p></div>';
            }
        } catch { }
    }

    async function loadCategories() {
        const scanId = document.getElementById('scanSelect')?.value;
        const catFilter = document.getElementById('categoryFilter');
        if (!scanId || !catFilter) return;

        try {
            const res = await api.get(`/scans/${scanId}/categories`);
            if (res.success && res.data) {
                catFilter.innerHTML = '<option value="">All Categories</option>' +
                    res.data.map(c => `<option value="${c}">${c}</option>`).join('');
            }
        } catch { }
    }

    async function loadFilterOptions() {
        const scanId = document.getElementById('scanSelect')?.value;
        if (!scanId) return;
        const category = document.getElementById('categoryFilter')?.value || '';
        const filterCols = ['category', 'target_type', 'principal_type', 'through', 'access_type', 'tenure', 'risk_level'];
        try {
            const results = await Promise.all(filterCols.map(col =>
                api.get(`/scans/${scanId}/filter-options?column=${col}${category ? '&category=' + encodeURIComponent(category) : ''}`)
            ));
            results.forEach((res, i) => {
                if (res.success) tableState.filterOptions[filterCols[i]] = res.data;
            });
        } catch { }
    }

    async function loadResults(page) {
        currentPage = page || 1;
        const scanId = document.getElementById('scanSelect')?.value;
        const category = document.getElementById('categoryFilter')?.value || '';
        const search = document.getElementById('searchInput')?.value || '';

        if (!scanId) return;
        // Show loading state
        const tableDiv = document.getElementById('resultsTable');
        if (tableDiv) tableDiv.innerHTML = '<div class="loading-skeleton"><div class="skeleton-row"></div><div class="skeleton-row"></div><div class="skeleton-row"></div><div class="skeleton-row"></div></div>';

        currentScanIdForResults = scanId;

        let url = `/scans/${scanId}/results?category=${encodeURIComponent(category)}&search=${encodeURIComponent(search)}&page=${currentPage}&pageSize=${pageSize}`;

        if (tableState.sortColumn) {
            url += `&sortColumn=${encodeURIComponent(tableState.sortColumn)}&sortDirection=${encodeURIComponent(tableState.sortDirection)}`;
        }
        for (const [col, val] of Object.entries(tableState.columnFilters)) {
            if (val) url += `&f_${encodeURIComponent(col)}=${encodeURIComponent(val)}`;
        }

        try {
            const allColumns = [
                { key: 'riskLevel', db: 'risk_level', label: 'Risk', filterable: true },
                { key: 'category', db: 'category', label: 'Category', filterable: true },
                { key: 'targetPath', db: 'target_path', label: 'Target', filterable: false },
                { key: 'targetType', db: 'target_type', label: 'Type', filterable: true },
                { key: 'principal', db: 'principal_entra_upn', label: 'Principal', filterable: false },
                { key: 'principalType', db: 'principal_type', label: 'Identity Type', filterable: true },
                { key: 'principalRole', db: 'principal_role', label: 'Role', filterable: false },
                { key: 'through', db: 'through', label: 'Through', filterable: true },
                { key: 'accessType', db: 'access_type', label: 'Access', filterable: true }
            ];
            const columns = allColumns.filter(c => !hiddenColumns.has(c.key));
            const visibleKeys = new Set(columns.map(c => c.key));

            const res = await api.get(url);
            if (!res.success) { showToast(res.error || 'Load failed', 'error'); return; }
            const { items, totalCount } = res.data;
            const totalPages = Math.ceil(totalCount / pageSize);

            if (items.length > 0) {
                tableDiv.innerHTML = `<table id="resultsTableEl">
                    ${buildSortableHeader(columns, () => loadResults())}
                    <tbody>${items.map((p, idx) => {
                        const principal = p.principalEntraUpn || p.principalSysName || p.principalEntraId || '';
                        const isGroupType = p.principalType === 'SecurityGroup' || p.principalType === 'M365Group';
                        const principalHtml = isGroupType
                            ? `<span class="group-link" onclick="event.stopPropagation();window.m365.showGroupMembers(${scanId},'${escapeAttr(p.principalEntraId || p.principalSysId || '')}','${escapeAttr(principal)}')" title="Click to view group members">👥 ${escapeHtml(principal)}</span>`
                            : escapeHtml(principal);
                        const cellMap = {
                            riskLevel: `<td><span class="risk-badge risk-${(p.riskLevel || 'low').toLowerCase()}">${escapeHtml(p.riskLevel || '')}</span></td>`,
                            category: `<td>${escapeHtml(p.category || '')}</td>`,
                            targetPath: `<td title="${escapeHtml(p.targetPath || '')}">${escapeHtml(truncate(p.targetPath, 45))}</td>`,
                            targetType: `<td>${escapeHtml(p.targetType || '')}</td>`,
                            principal: `<td>${principalHtml}</td>`,
                            principalType: `<td>${escapeHtml(p.principalType || '')}</td>`,
                            principalRole: `<td>${escapeHtml(p.principalRole || '')}</td>`,
                            through: `<td>${escapeHtml(p.through || '')}</td>`,
                            accessType: `<td>${escapeHtml(p.accessType || '')}</td>`
                        };
                        return `<tr class="clickable-row" data-idx="${idx}">
                            ${columns.map(c => cellMap[c.key] || '').join('')}
                        </tr>`;
                    }).join('')}</tbody>
                </table>`;

                const tableEl = document.getElementById('resultsTableEl');
                attachTableListeners(tableEl, () => loadResults(), () => { currentPage = 1; loadResults(); });

                tableEl.querySelectorAll('.clickable-row').forEach(row => {
                    row.addEventListener('click', () => {
                        const idx = parseInt(row.dataset.idx);
                        const entry = items[idx];
                        if (entry) {
                            entry.scanId = scanId;
                            showDetailPanel(entry);
                        }
                    });
                });
            } else {
                tableDiv.innerHTML = '<div class="empty-state"><p>No results found</p></div>';
            }

            const pagDiv = document.getElementById('pagination');
            pagDiv.innerHTML = `
                <button ${currentPage <= 1 ? 'disabled' : ''} onclick="window.m365.loadResults(${currentPage - 1})">← Prev</button>
                <span class="page-info">Page ${currentPage} of ${totalPages} (${totalCount.toLocaleString()} results)</span>
                <button ${currentPage >= totalPages ? 'disabled' : ''} onclick="window.m365.loadResults(${currentPage + 1})">Next →</button>
            `;
        } catch (e) {
            showToast('Failed to load results', 'error');
        }
    }

    // User Permissions Lookup
    async function renderUserLookup() {
        const app = document.getElementById('app');

        app.innerHTML = `
            <div class="card">
                <h2>🔍 User Permissions Lookup</h2>
                <p style="color:var(--text-muted);margin-bottom:16px">Search for all permissions a user has — directly, through groups, or as eligible. Results are based on scan data.</p>
                ${!state.connected ? `
                    <div class="notice notice-warning" style="margin-bottom:16px">
                        <strong>Not connected.</strong> Connect to Microsoft 365 and run a scan to see results.
                    </div>
                ` : ''}
                <div style="display:flex;gap:12px;flex-wrap:wrap;align-items:flex-end">
                    <div class="form-group" style="margin:0;min-width:250px">
                        <label>Scan</label>
                        <select id="userLookupScan" style="padding:8px;background:var(--bg-input);border:1px solid var(--border);border-radius:8px;color:var(--text);width:100%"></select>
                    </div>
                    <div class="form-group" style="margin:0;flex:1;min-width:250px">
                        <label>User (UPN, name, or Entra ID)</label>
                        <input id="userLookupInput" type="text" placeholder="e.g. john@contoso.com" style="padding:8px;background:var(--bg-input);border:1px solid var(--border);border-radius:8px;color:var(--text);width:100%">
                    </div>
                    <button class="btn btn-primary" onclick="window.m365.searchUserPerms()">🔍 Search</button>
                </div>
                <div id="userLookupNotice" style="margin-top:12px"></div>
            </div>
            <div class="card" id="userResultsCard" style="display:none">
                <h2 id="userResultsTitle">Results</h2>
                <div class="table-wrapper" id="userResultsTable"></div>
                <div class="pagination" id="userPagination"></div>
            </div>
        `;

        try {
            const scans = await api.get('/scans' + tenantQuery());
            if (scans.success && scans.data.length > 0) {
                const sel = document.getElementById('userLookupScan');
                const completedScans = scans.data.filter(s => s.status === 'Completed');
                if (completedScans.length === 0) {
                    sel.innerHTML = '<option value="">No completed scans available</option>';
                    document.getElementById('userLookupNotice').innerHTML = `
                        <div class="notice notice-warning">No completed scans found. Run a full scan first to get accurate results.</div>
                    `;
                } else {
                    sel.innerHTML = completedScans.map(s =>
                        `<option value="${s.id}">Scan #${s.id} — ${new Date(s.startedAt).toLocaleDateString()} — ${s.scanTypes} (${(s.totalPermissions || 0).toLocaleString()} perms)</option>`
                    ).join('');
                    sel.addEventListener('change', updateScanNotice);
                    updateScanNotice();
                }
            } else {
                document.getElementById('userLookupScan').innerHTML = '<option value="">No scans available</option>';
                document.getElementById('userLookupNotice').innerHTML = `
                    <div class="notice notice-warning">No scans have been run yet. Run a scan to search for user permissions.</div>
                `;
            }
        } catch { }

        document.getElementById('userLookupInput')?.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') window.m365.searchUserPerms();
        });
    }

    function updateScanNotice() {
        const sel = document.getElementById('userLookupScan');
        const notice = document.getElementById('userLookupNotice');
        if (!sel || !notice) return;
        const option = sel.selectedOptions[0];
        if (!option) return;
        const text = option.textContent;
        const allTypes = ['SharePoint', 'Entra', 'Exchange', 'OneDrive', 'PowerBI', 'PowerAutomate', 'Azure', 'AzureDevOps', 'Purview'];
        const missing = allTypes.filter(t => !text.includes(t));
        if (missing.length > 0) {
            notice.innerHTML = `<div class="notice notice-info">This scan did not include: <strong>${missing.join(', ')}</strong>. Results for those services will not appear.</div>`;
        } else {
            notice.innerHTML = '';
        }
    }

    let userLookupPage = 1;
    let userTableState = {
        sortColumn: null,
        sortDirection: 'asc',
        columnFilters: {},
        filterOptions: {}
    };

    async function searchUserPerms(page) {
        userLookupPage = page || 1;
        const scanId = document.getElementById('userLookupScan')?.value;
        const user = document.getElementById('userLookupInput')?.value?.trim();
        if (!scanId) { showToast('Select a scan first', 'error'); return; }
        if (!user) { showToast('Enter a user to search for', 'error'); return; }

        let url = `/scans/${scanId}/user-permissions?user=${encodeURIComponent(user)}&page=${userLookupPage}&pageSize=50`;
        if (userTableState.sortColumn) {
            url += `&sortColumn=${encodeURIComponent(userTableState.sortColumn)}&sortDirection=${encodeURIComponent(userTableState.sortDirection)}`;
        }
        for (const [col, val] of Object.entries(userTableState.columnFilters)) {
            if (val) url += `&f_${encodeURIComponent(col)}=${encodeURIComponent(val)}`;
        }

        try {
            const res = await api.get(url);
            if (!res.success) { showToast(res.error || 'Search failed', 'error'); return; }

            const { items, totalCount } = res.data;
            const totalPages = Math.ceil(totalCount / 50);
            const card = document.getElementById('userResultsCard');
            card.style.display = '';

            document.getElementById('userResultsTitle').textContent = `Results for "${user}" (${totalCount.toLocaleString()} permissions)`;

            const columns = [
                { key: 'category', db: 'category', label: 'Category', filterable: true },
                { key: 'targetPath', db: 'target_path', label: 'Target', filterable: false },
                { key: 'targetType', db: 'target_type', label: 'Type', filterable: true },
                { key: 'principalRole', db: 'principal_role', label: 'Role', filterable: false },
                { key: 'through', db: 'through', label: 'Through', filterable: true },
                { key: 'accessType', db: 'access_type', label: 'Access', filterable: true },
                { key: 'tenure', db: 'tenure', label: 'Tenure', filterable: true }
            ];

            const savedState = tableState;
            tableState = userTableState;

            const tableDiv = document.getElementById('userResultsTable');
            if (items.length === 0) {
                tableDiv.innerHTML = '<div class="empty-state"><p>No permissions found for this user in the selected scan.</p></div>';
            } else {
                tableDiv.innerHTML = `<table id="userResultsTableEl">
                    ${buildSortableHeader(columns, () => searchUserPerms())}
                    <tbody>${items.map((p, idx) => `<tr class="clickable-row" data-uidx="${idx}">
                        <td>${escapeHtml(p.category || '')}</td>
                        <td title="${escapeHtml(p.targetPath || '')}">${escapeHtml(truncate(p.targetPath, 45))}</td>
                        <td>${escapeHtml(p.targetType || '')}</td>
                        <td>${escapeHtml(p.principalRole || '')}</td>
                        <td>${escapeHtml(p.through || '')}</td>
                        <td>${escapeHtml(p.accessType || '')}</td>
                        <td>${escapeHtml(p.tenure || '')}</td>
                    </tr>`).join('')}</tbody>
                </table>`;

                const userTableEl = document.getElementById('userResultsTableEl');
                attachTableListeners(userTableEl, () => searchUserPerms(), () => { userLookupPage = 1; searchUserPerms(); });

                userTableEl.querySelectorAll('.clickable-row').forEach(row => {
                    row.addEventListener('click', () => {
                        const idx = parseInt(row.dataset.uidx);
                        const entry = items[idx];
                        if (entry) { entry.scanId = scanId; showDetailPanel(entry); }
                    });
                });
            }

            tableState = savedState;

            const pagDiv = document.getElementById('userPagination');
            pagDiv.innerHTML = totalPages > 1 ? `
                <button ${userLookupPage <= 1 ? 'disabled' : ''} onclick="window.m365.searchUserPerms(${userLookupPage - 1})">← Prev</button>
                <span class="page-info">Page ${userLookupPage} of ${totalPages}</span>
                <button ${userLookupPage >= totalPages ? 'disabled' : ''} onclick="window.m365.searchUserPerms(${userLookupPage + 1})">Next →</button>
            ` : '';
        } catch (e) {
            showToast('Search failed: ' + e.message, 'error');
        }
    }

    // Compare
    async function renderCompare() {
        const app = document.getElementById('app');
        app.innerHTML = `
            <div class="card">
                <h2>Compare Scans</h2>
                <div style="display:flex;gap:16px;flex-wrap:wrap">
                    <div class="form-group" style="flex:1;min-width:200px">
                        <label>Baseline Scan</label>
                        <select id="oldScanSelect" style="width:100%;padding:10px;background:var(--bg-input);border:1px solid var(--border);border-radius:8px;color:var(--text)"></select>
                    </div>
                    <div class="form-group" style="flex:1;min-width:200px">
                        <label>Comparison Scan</label>
                        <select id="newScanSelect" style="width:100%;padding:10px;background:var(--bg-input);border:1px solid var(--border);border-radius:8px;color:var(--text)"></select>
                    </div>
                </div>
                <div class="btn-group">
                    <button class="btn btn-primary" onclick="window.m365.runCompare()">🔄 Compare</button>
                    <button class="btn btn-secondary" id="btnExportCompare" style="display:none" onclick="window.m365.exportCompare()">📥 Export Comparison</button>
                </div>
            </div>
            <div class="card" id="compareResults" style="display:none">
                <h2>Comparison Results</h2>
                <div class="stats-grid" id="compareStats"></div>
                <div class="table-wrapper" id="compareTable"></div>
            </div>
        `;

        try {
            const scans = await api.get('/scans' + tenantQuery());
            if (scans.success && scans.data.length > 0) {
                const completedScans = scans.data.filter(s => s.status === 'Completed');
                if (completedScans.length >= 1) {
                    const options = completedScans.map(s =>
                        `<option value="${s.id}">Scan #${s.id} — ${s.tenantDomain ? s.tenantDomain + ' — ' : ''}${new Date(s.startedAt).toLocaleDateString()} (${s.scanTypes}, ${s.totalPermissions || 0} perms)</option>`
                    ).join('');
                    document.getElementById('oldScanSelect').innerHTML = options;
                    document.getElementById('newScanSelect').innerHTML = options;
                    document.getElementById('newScanSelect').selectedIndex = 0;
                    if (completedScans.length > 1)
                        document.getElementById('oldScanSelect').selectedIndex = 1;
                } else {
                    document.getElementById('oldScanSelect').innerHTML = '<option>No completed scans</option>';
                    document.getElementById('newScanSelect').innerHTML = '<option>No completed scans</option>';
                }
            } else {
                document.getElementById('oldScanSelect').innerHTML = '<option>No scans available</option>';
                document.getElementById('newScanSelect').innerHTML = '<option>No scans available</option>';
            }
        } catch { }
    }

    // Trends
    async function renderTrends() {
        const app = document.getElementById('app');
        app.innerHTML = `
            <div class="card">
                <h2>📈 Permission Trends</h2>
                <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
                    <p style="color:var(--text-muted);margin:0">Track how permissions change across scans.</p>
                    <select id="trendTenantFilter" style="padding:4px 8px;border-radius:4px;border:1px solid var(--border);background:var(--card-bg);color:var(--text)">
                        <option value="">All tenants</option>
                    </select>
                </div>
                <div style="max-height:350px;position:relative"><canvas id="trendChart"></canvas></div>
            </div>
            <div class="card" id="trendTable" style="display:none">
                <h2>Trend Data</h2>
                <div class="table-wrapper" id="trendTableBody"></div>
            </div>
        `;

        try {
            const trendsTenantId = state.tenantId ? `&tenantId=${encodeURIComponent(state.tenantId)}` : '';
            const res = await api.get('/trends?limit=50' + trendsTenantId);
            if (!res.success || !res.data || res.data.length === 0) {
                document.getElementById('trendChart').parentElement.innerHTML += '<div class="empty-state"><p>No trend data yet. Complete at least 2 scans.</p></div>';
                return;
            }
            const allData = res.data;

            // Populate tenant filter dropdown
            const tenants = [...new Set(allData.map(d => d.tenantDomain || 'Unknown').filter(t => t))];
            const filterEl = document.getElementById('trendTenantFilter');
            if (tenants.length <= 1) {
                filterEl.style.display = 'none';
            } else {
                tenants.forEach(t => {
                    const opt = document.createElement('option');
                    opt.value = t;
                    opt.textContent = t;
                    filterEl.appendChild(opt);
                });
                // Default to current tenant if connected
                const currentDomain = state.tenantDomain || '';
                if (currentDomain && tenants.includes(currentDomain)) {
                    filterEl.value = currentDomain;
                }
            }

            const showMultipleTenants = tenants.length > 1;

            function applyTrendFilter(selectedTenant) {
                const data = selectedTenant ? allData.filter(d => (d.tenantDomain || 'Unknown') === selectedTenant) : allData;
                if (data.length === 0) {
                    document.getElementById('trendTable').style.display = 'none';
                    return;
                }

                const trendCard = document.getElementById('trendTable');
                trendCard.style.display = '';
                document.getElementById('trendTableBody').innerHTML = `<table>
                    <thead><tr>${showMultipleTenants ? '<th>Tenant</th>' : ''}<th>Scan</th><th>Date</th><th>Total</th><th>Critical</th><th>High</th><th>Medium</th><th>Low</th><th>Info</th></tr></thead>
                    <tbody>${data.map(d => `<tr>
                        ${showMultipleTenants ? `<td title="${escapeAttr(d.tenantDomain || '')}">${escapeHtml(truncate(d.tenantDomain || 'Unknown', 30))}</td>` : ''}
                        <td>#${d.scanId}</td>
                        <td>${new Date(d.startedAt).toLocaleDateString()}</td>
                        <td>${d.totalPermissions.toLocaleString()}</td>
                        <td style="color:#b71c1c">${d.critical}</td>
                        <td style="color:#f44336">${d.high}</td>
                        <td style="color:#ff9800">${d.medium}</td>
                        <td style="color:#4caf50">${d.low}</td>
                        <td style="color:#2196f3">${d.info}</td>
                    </tr>`).join('')}</tbody>
                </table>`;

                // Destroy existing chart if any
                const canvas = document.getElementById('trendChart');
                if (canvas._chartInstance) { canvas._chartInstance.destroy(); }

                if (typeof Chart !== 'undefined') {
                    const ctx = canvas.getContext('2d');
                    const chartLabels = data.map(d => showMultipleTenants ? `#${d.scanId} (${truncate(d.tenantDomain || '?', 15)})` : `#${d.scanId}`);
                    const chart = new Chart(ctx, {
                        type: 'line',
                        data: {
                            labels: chartLabels,
                            datasets: [
                                { label: 'Critical', data: data.map(d => d.critical), borderColor: '#b71c1c', backgroundColor: 'rgba(183,28,28,0.1)', tension: 0.3 },
                                { label: 'High', data: data.map(d => d.high), borderColor: '#f44336', backgroundColor: 'rgba(244,67,54,0.1)', tension: 0.3 },
                                { label: 'Medium', data: data.map(d => d.medium), borderColor: '#ff9800', backgroundColor: 'rgba(255,152,0,0.1)', tension: 0.3 },
                                { label: 'Low', data: data.map(d => d.low), borderColor: '#4caf50', backgroundColor: 'rgba(76,175,80,0.1)', tension: 0.3 },
                                { label: 'Info', data: data.map(d => d.info), borderColor: '#2196f3', backgroundColor: 'rgba(33,150,243,0.1)', tension: 0.3 }
                            ]
                        },
                        options: {
                            responsive: true,
                            maintainAspectRatio: false,
                            interaction: { intersect: false, mode: 'index' },
                            scales: { y: { beginAtZero: true } },
                            plugins: { legend: { position: 'bottom' } }
                        }
                    });
                    canvas._chartInstance = chart;
                } else {
                    canvas.style.display = 'none';
                }
            }

            filterEl.addEventListener('change', () => applyTrendFilter(filterEl.value));
            applyTrendFilter(filterEl.value);
        } catch (e) {
            showToast('Failed to load trends', 'error');
        }
    }

    // Audit Log
    async function renderAudit() {
        const app = document.getElementById('app');
        app.innerHTML = `
            <div class="card">
                <h2>📋 Audit Log</h2>
                <p style="color:var(--text-muted);margin-bottom:16px">Track all actions performed in the application.</p>
                <div class="table-wrapper" id="auditTableBody">
                    <div class="empty-state"><p>Loading...</p></div>
                </div>
            </div>
        `;

        try {
            const res = await api.get('/audit' + tenantQuery('?limit=200'));
            if (!res.success || !res.data || res.data.length === 0) {
                document.getElementById('auditTableBody').innerHTML = '<div class="empty-state"><p>No audit entries yet.</p></div>';
                return;
            }
            document.getElementById('auditTableBody').innerHTML = `<table>
                <thead><tr><th>Timestamp</th><th>Action</th><th>User</th><th>Details</th><th>Scan</th></tr></thead>
                <tbody>${res.data.map(a => `<tr>
                    <td style="white-space:nowrap">${new Date(a.timestamp + 'Z').toLocaleString()}</td>
                    <td><span class="audit-action">${escapeHtml(a.action)}</span></td>
                    <td>${escapeHtml(a.userName || '—')}</td>
                    <td style="max-width:400px;overflow:hidden;text-overflow:ellipsis" title="${escapeAttr(a.details)}">${escapeHtml(truncate(a.details, 60))}</td>
                    <td>${a.scanId ? `<a href="#/results?id=${a.scanId}">#${a.scanId}</a>` : '—'}</td>
                </tr>`).join('')}</tbody>
            </table>`;
        } catch (e) {
            showToast('Failed to load audit log', 'error');
        }
    }

    // Policies
    let policyConditions = [];
    let lastEvalEntries = {};

    const POLICY_FIELDS = [
        { value: 'category', label: 'Category' },
        { value: 'principal_type', label: 'Principal Type' },
        { value: 'principal_role', label: 'Role' },
        { value: 'principal_entra_upn', label: 'Principal UPN' },
        { value: 'principal_entra_id', label: 'Principal Entra ID' },
        { value: 'principal_sys_id', label: 'Principal Sys ID' },
        { value: 'principal_sys_name', label: 'Principal Sys Name' },
        { value: 'through', label: 'Through' },
        { value: 'access_type', label: 'Access Type' },
        { value: 'tenure', label: 'Tenure' },
        { value: 'target_type', label: 'Target Type' },
        { value: 'target_path', label: 'Target Path' },
        { value: 'target_id', label: 'Target ID' },
    ];

    const POLICY_OPERATORS = [
        { value: 'equals', label: 'Equals' },
        { value: 'notEquals', label: 'Not equals' },
        { value: 'contains', label: 'Contains' },
        { value: 'notContains', label: 'Not contains' },
        { value: 'startsWith', label: 'Starts with' },
        { value: 'regex', label: 'Regex' },
    ];

    function renderConditionRow(cond, idx) {
        return `<div style="display:flex;gap:8px;align-items:center;margin-bottom:6px" data-cond-idx="${idx}">
            <select data-role="field" style="flex:1;min-width:120px">
                ${POLICY_FIELDS.map(f => `<option value="${f.value}" ${cond.field === f.value ? 'selected' : ''}>${f.label}</option>`).join('')}
            </select>
            <select data-role="operator" style="flex:1;min-width:100px">
                ${POLICY_OPERATORS.map(o => `<option value="${o.value}" ${cond.operator === o.value ? 'selected' : ''}>${o.label}</option>`).join('')}
            </select>
            <input data-role="value" type="text" value="${escapeAttr(cond.value || '')}" placeholder="Value" style="flex:2;min-width:160px">
            <button type="button" class="btn btn-secondary" style="padding:2px 8px;font-size:0.85em;color:var(--error);flex-shrink:0" onclick="window.m365.removeCondition(${idx})">✕</button>
        </div>`;
    }

    function renderConditionsEditor() {
        const container = document.getElementById('conditionsEditor');
        if (!container) return;
        container.innerHTML = policyConditions.map((c, i) => renderConditionRow(c, i)).join('')
            + `<button type="button" class="btn btn-secondary" style="padding:3px 10px;font-size:0.8em;margin-top:4px" onclick="window.m365.addCondition()">+ Add Condition</button>`;
    }

    function collectConditions() {
        const rows = document.querySelectorAll('[data-cond-idx]');
        return Array.from(rows).map(row => ({
            field: row.querySelector('[data-role="field"]').value,
            operator: row.querySelector('[data-role="operator"]').value,
            value: row.querySelector('[data-role="value"]').value,
        }));
    }

    async function renderPolicies() {
        const app = document.getElementById('app');
        app.innerHTML = `
            <div class="card">
                <h2>📜 Policy Rules</h2>
                <p style="color:var(--text-muted);margin-bottom:16px">Policies define risk scoring rules. Each policy contains one or more conditions (all must match). During scans, permissions are scored by the highest-severity matching policy.</p>
                <div class="btn-group" style="margin-bottom:16px">
                    <button class="btn btn-primary" onclick="window.m365.showPolicyForm()">+ New Policy</button>
                    <button class="btn btn-secondary" id="evalPoliciesBtn" onclick="window.m365.evaluatePolicies()">▶ Evaluate Latest Scan</button>
                    <button class="btn btn-secondary" onclick="window.m365.resetDefaultPolicies()" title="Delete all default policies and re-create them from built-in definitions">🔄 Reset Defaults</button>
                </div>
                <div class="table-wrapper" id="policiesTable">
                    <div class="empty-state"><p>Loading...</p></div>
                </div>
            </div>
            <div class="card" id="violationsCard" style="display:none">
                <h2>Policy Violations</h2>
                <div class="table-wrapper" id="violationsTable"></div>
            </div>
        `;

        await loadPolicies();
    }

    async function loadPolicies() {
        try {
            const res = await api.get('/policies');
            if (!res.success || !res.data) return;

            const policies = res.data;
            const tableDiv = document.getElementById('policiesTable');
            if (policies.length === 0) {
                tableDiv.innerHTML = '<div class="empty-state"><p>No policies defined yet. Create your first rule or click "Reset Defaults" to load built-in policies.</p></div>';
                return;
            }

            tableDiv.innerHTML = `<table>
                <thead><tr><th>Enabled</th><th>Name</th><th>Severity</th><th>Conditions</th><th>Category</th><th>Actions</th></tr></thead>
                <tbody>${policies.map(p => {
                    const conds = (p.conditions || []);
                    const condSummary = conds.length === 0 ? '<em>none</em>'
                        : conds.map(c => `<span style="white-space:nowrap">${escapeHtml(c.field)} ${escapeHtml(c.operator)} <code>${escapeHtml(c.value?.length > 40 ? c.value.substring(0,37)+'...' : c.value)}</code></span>`).join(' <strong>AND</strong> ');
                    const defaultBadge = p.isDefault ? ' <span style="font-size:0.7em;background:var(--bg-input);color:var(--text-muted);padding:1px 5px;border-radius:4px;vertical-align:middle">default</span>' : '';
                    return `<tr>
                    <td><span style="color:${p.enabled ? 'var(--success)' : 'var(--text-muted)'};cursor:pointer" onclick="window.m365.togglePolicy(${p.id},${!p.enabled})" title="Click to ${p.enabled ? 'disable' : 'enable'}">${p.enabled ? '●' : '○'}</span></td>
                    <td title="${escapeAttr(p.description || '')}">${escapeHtml(p.name)}${defaultBadge}</td>
                    <td><span class="risk-badge risk-${(p.severity || 'high').toLowerCase()}">${escapeHtml(p.severity)}</span></td>
                    <td style="font-size:0.8em;line-height:1.5;max-width:400px">${condSummary}</td>
                    <td>${escapeHtml(p.categoryFilter || 'All')}</td>
                    <td style="white-space:nowrap">
                        <button class="btn btn-secondary" style="padding:2px 8px;font-size:0.8em" onclick="window.m365.editPolicy(${p.id})">Edit</button>
                        <button class="btn btn-secondary" style="padding:2px 8px;font-size:0.8em;color:var(--error)" onclick="window.m365.deletePolicy(${p.id})">Delete</button>
                    </td>
                </tr>`;
                }).join('')}</tbody>
            </table>`;
        } catch (e) {
            showToast('Failed to load policies', 'error');
        }
    }

    // Settings
    async function renderSettings() {
        const app = document.getElementById('app');
        app.innerHTML = `
            <div class="card">
                <h2>Settings</h2>
                <div id="settingsForm">Loading...</div>
            </div>
            <div class="card" style="margin-top:16px">
                <h2>Database</h2>
                <div id="dbInfo">Loading...</div>
            </div>
        `;

        try {
            const res = await api.get('/config');
            if (!res.success) return;
            const cfg = res.data;

            document.getElementById('settingsForm').innerHTML = `
                <div class="form-group">
                    <label>GUI Port</label>
                    <input id="cfgGuiPort" type="number" value="${cfg.guiPort || 8080}" min="1024" max="65535">
                </div>
                <div class="form-group">
                    <label>Max Parallel Threads</label>
                    <input id="cfgMaxThreads" type="number" value="${cfg.maxThreads || 5}" min="1" max="20">
                </div>
                <div class="form-group">
                    <label>Default Output Format</label>
                    <select id="cfgOutputFormat">
                        <option value="XLSX" ${cfg.outputFormat === 'XLSX' ? 'selected' : ''}>XLSX (Excel)</option>
                        <option value="CSV" ${cfg.outputFormat === 'CSV' ? 'selected' : ''}>CSV</option>
                    </select>
                </div>
                <div class="form-group">
                    <label>Log Level</label>
                    <select id="cfgLogLevel">
                        <option value="Minimal" ${cfg.logLevel === 'Minimal' ? 'selected' : ''}>Minimal</option>
                        <option value="Normal" ${cfg.logLevel === 'Normal' ? 'selected' : ''}>Normal</option>
                        <option value="Verbose" ${cfg.logLevel === 'Verbose' ? 'selected' : ''}>Verbose</option>
                    </select>
                </div>
                <div class="form-group">
                    <label>Default Timeout (minutes)</label>
                    <input id="cfgTimeout" type="number" value="${cfg.defaultTimeoutMinutes || 120}" min="1" max="1440">
                </div>
                <div class="btn-group">
                    <button class="btn btn-primary" onclick="window.m365.saveSettings()">💾 Save</button>
                </div>
            `;
        } catch {
            document.getElementById('settingsForm').innerHTML = '<p>Failed to load settings.</p>';
        }

        // Load database info
        try {
            const dbRes = await api.get('/database');
            if (!dbRes.success) { document.getElementById('dbInfo').innerHTML = '<p>Failed to load database info.</p>'; return; }
            const db = dbRes.data;
            const totalRows = Object.values(db.tableCounts).reduce((a, b) => a + b, 0);

            document.getElementById('dbInfo').innerHTML = `
                <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px">
                    <div style="background:var(--bg-secondary);padding:12px;border-radius:8px">
                        <div style="color:var(--text-muted);font-size:0.8em">Database Size</div>
                        <div style="font-size:1.4em;font-weight:600">${db.sizeMB} MB</div>
                    </div>
                    <div style="background:var(--bg-secondary);padding:12px;border-radius:8px">
                        <div style="color:var(--text-muted);font-size:0.8em">Total Records</div>
                        <div style="font-size:1.4em;font-weight:600">${totalRows.toLocaleString()}</div>
                    </div>
                </div>
                <details style="margin-bottom:16px">
                    <summary style="cursor:pointer;color:var(--text-muted);font-size:0.85em">Table Details</summary>
                    <table class="data-table" style="margin-top:8px;font-size:0.85em">
                        <thead><tr><th>Table</th><th style="text-align:right">Rows</th></tr></thead>
                        <tbody>
                            ${Object.entries(db.tableCounts).map(([t, c]) =>
                                `<tr><td>${escapeHtml(t)}</td><td style="text-align:right">${c.toLocaleString()}</td></tr>`
                            ).join('')}
                        </tbody>
                    </table>
                </details>
                <div style="padding:12px;background:var(--bg-secondary);border-radius:8px;margin-bottom:16px">
                    <div style="color:var(--text-muted);font-size:0.8em;word-break:break-all">Path: ${escapeHtml(db.path)}</div>
                </div>
                <div class="btn-group">
                    <button class="btn btn-danger" onclick="window.m365.resetDatabase()">🗑️ Reset Database</button>
                </div>
                <p style="color:var(--text-muted);font-size:0.8em;margin-top:8px">Deletes all scans, permissions, and logs. Settings and policies are preserved.</p>
            `;
        } catch {
            document.getElementById('dbInfo').innerHTML = '<p>Failed to load database info.</p>';
        }
    }

    // ── Actions ─────────────────────────────────────────────────
    window.m365 = {
        async connect() {
            try {
                showToast('Opening browser for sign-in...', 'info');
                const res = await api.post('/connect');
                if (res.success) {
                    await refreshStatus();
                    showToast(`Connected to ${state.tenantDomain}`, 'success');
                    // Check tenant size and display recommendation
                    try {
                        const countRes = await api.get('/user-count');
                        if (countRes.success && countRes.data && countRes.data.recommendation) {
                            showToast(`${countRes.data.userCount.toLocaleString()} users detected`, 'info');
                            showModal('Tenant Size Notice', `
                                <p style="margin-bottom:12px"><strong>${countRes.data.userCount.toLocaleString()}</strong> user accounts detected in this tenant.</p>
                                <p style="color:var(--text-muted)">${escapeHtml(countRes.data.recommendation)}</p>
                                <div style="margin-top:16px">
                                    <a href="https://m365permissions.com" target="_blank" rel="noopener" class="btn btn-primary" style="text-decoration:none">Learn More</a>
                                    <button class="btn btn-secondary" style="margin-left:8px" onclick="document.getElementById('modalOverlay').style.display='none'">Continue</button>
                                </div>
                            `);
                        }
                    } catch { /* best effort */ }
                    navigate();
                } else {
                    showToast(res.error || 'Connection failed', 'error');
                }
            } catch (e) {
                showToast('Connection failed: ' + e.message, 'error');
            }
        },

        async disconnect() {
            try {
                const res = await api.post('/disconnect');
                if (res.success) {
                    state.connected = false;
                    state.tenantId = '';
                    state.tenantDomain = '';
                    updateNavStatus();
                    showToast('Disconnected', 'info');
                    navigate();
                } else {
                    showToast(res.error || 'Disconnect failed', 'error');
                }
            } catch (e) {
                showToast('Disconnect failed: ' + e.message, 'error');
            }
        },

        async precheckScan() {
            const checkboxes = document.querySelectorAll('.scan-cat-card input:checked');
            const types = Array.from(checkboxes).map(c => c.value);
            if (types.length === 0) { showToast('Select at least one scan type', 'error'); return; }

            const precheckDiv = document.getElementById('precheckResults');
            precheckDiv.style.display = '';
            precheckDiv.innerHTML = '<div style="color:var(--text-muted);font-size:0.85em">Checking permissions...</div>';

            try {
                const res = await api.post('/scan/precheck', { scanTypes: types });
                if (!res.success) { precheckDiv.innerHTML = `<div class="notice notice-warning">${escapeHtml(res.error || 'Pre-check failed')}</div>`; return; }

                const issues = res.data;
                const entries = Object.entries(issues).filter(([, v]) => v && v.length > 0);
                if (entries.length === 0) {
                    precheckDiv.innerHTML = '<div class="notice notice-info">✓ All permission and role checks passed</div>';
                } else {
                    const hasPermIssues = entries.some(([, warnings]) => warnings.some(w => !w.startsWith('Missing role:')));
                    let html = entries.map(([scanType, warnings]) => {
                        const roleWarnings = warnings.filter(w => w.startsWith('Missing role:'));
                        const permIssues = warnings.filter(w => !w.startsWith('Missing role:'));
                        let inner = `<div style="margin-bottom:8px"><strong>${escapeHtml(scanType)}:</strong>`;
                        if (permIssues.length > 0) {
                            inner += `<div class="notice notice-warning" style="margin:4px 0 6px 0">
                                <strong>API Permissions</strong>
                                <ul style="margin:4px 0 0 16px;padding:0">${permIssues.map(w => `<li>${escapeHtml(w)}</li>`).join('')}</ul>
                            </div>`;
                        }
                        if (roleWarnings.length > 0) {
                            inner += `<div class="notice notice-info" style="margin:4px 0 6px 0">
                                <strong>Entra Directory Roles</strong>
                                <ul style="margin:4px 0 0 16px;padding:0">${roleWarnings.map(w => `<li>${escapeHtml(w)}</li>`).join('')}</ul>
                            </div>`;
                        }
                        inner += '</div>';
                        return inner;
                    }).join('');
                    if (hasPermIssues) {
                        html += `<div style="margin-top:8px;padding:10px;border-radius:6px;background:var(--bg)">
                            <p style="margin:0 0 8px 0;font-size:0.85em;color:var(--text-muted)">API permission issues can often be resolved by re-consenting the app registration. An admin can grant the missing permissions:</p>
                            <button class="btn btn-primary" onclick="window.m365.reconsentPermissions()" style="font-size:0.85em">🔑 Re-consent App Permissions</button>
                        </div>`;
                    }
                    precheckDiv.innerHTML = html;
                }
            } catch (e) {
                precheckDiv.innerHTML = `<div class="notice notice-warning">Pre-check failed: ${escapeHtml(e.message)}</div>`;
            }
        },

        async reconsentPermissions() {
            showToast('Opening browser for admin consent...', 'info');
            try {
                const res = await api.post('/reconsent');
                if (res.success) {
                    showToast('Permissions re-consented successfully! Run the pre-check again to verify.', 'success');
                    await refreshStatus();
                } else {
                    showToast(res.error || 'Consent failed', 'error');
                }
            } catch (e) {
                showToast('Consent failed: ' + e.message, 'error');
            }
        },

        async startScan() {
            const checkboxes = document.querySelectorAll('.scan-cat-card input:checked');
            const types = Array.from(checkboxes).map(c => c.value);
            if (types.length === 0) { showToast('Select at least one scan type', 'error'); return; }

            try {
                const res = await api.post('/scan/start', { scanTypes: types });
                if (res.success) {
                    state.scanRunning = true;
                    state.currentScanId = res.data?.scanId;
                    updateNavStatus();
                    startProgressPolling();
                    showToast('Scan started', 'success');
                } else {
                    showToast(res.error || 'Failed to start scan', 'error');
                }
            } catch (e) {
                showToast('Error: ' + e.message, 'error');
            }
        },

        startQuickScan() { window.location.hash = '#/scan'; },

        async cancelScan() {
            try {
                await api.post('/scan/cancel');
                state.scanRunning = false;
                updateNavStatus();
                if (pollInterval) { clearInterval(pollInterval); pollInterval = null; }
                showToast('Scan cancelled', 'info');
                navigate();
            } catch (e) {
                showToast('Error: ' + e.message, 'error');
            }
        },

        async exportResults() {
            const scanId = document.getElementById('scanSelect')?.value;
            if (!scanId) { showToast('Select a scan first', 'error'); return; }

            try {
                // Use configured output format
                const cfgRes = await api.get('/config');
                const format = (cfgRes.success && cfgRes.data?.outputFormat) ? cfgRes.data.outputFormat.toLowerCase() : 'xlsx';
                const res = await api.getBlob(`/scans/${scanId}/export?format=${format}`);
                if (!res.ok) { showToast('Export failed', 'error'); return; }
                const blob = await res.blob();
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = `M365Permissions_Scan${scanId}.${format}`;
                document.body.appendChild(a);
                a.click();
                a.remove();
                URL.revokeObjectURL(url);
                showToast('Export downloaded', 'success');
            } catch (e) {
                showToast('Export failed: ' + e.message, 'error');
            }
        },

        async exportCompare() {
            const oldId = document.getElementById('oldScanSelect')?.value;
            const newId = document.getElementById('newScanSelect')?.value;
            if (!oldId || !newId) { showToast('Select two scans first', 'error'); return; }
            try {
                const res = await fetch('/api/compare/export', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ oldScanId: parseInt(oldId), newScanId: parseInt(newId) })
                });
                if (!res.ok) { showToast('Export failed', 'error'); return; }
                const blob = await res.blob();
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = `M365Permissions_Compare_${oldId}_vs_${newId}.xlsx`;
                document.body.appendChild(a);
                a.click();
                a.remove();
                URL.revokeObjectURL(url);
                showToast('Comparison export downloaded', 'success');
            } catch (e) {
                showToast('Export failed: ' + e.message, 'error');
            }
        },

        async runCompare() {
            const oldId = document.getElementById('oldScanSelect')?.value;
            const newId = document.getElementById('newScanSelect')?.value;
            if (!oldId || !newId) { showToast('Select two scans', 'error'); return; }
            if (oldId === newId) { showToast('Select two different scans', 'error'); return; }

            try {
                const res = await api.post('/compare', { oldScanId: parseInt(oldId), newScanId: parseInt(newId) });
                if (!res.success) { showToast(res.error || 'Compare failed', 'error'); return; }

                const r = res.data;
                document.getElementById('compareResults').style.display = '';
                document.getElementById('btnExportCompare').style.display = '';
                document.getElementById('compareStats').innerHTML = `
                    <div class="stat-card"><div class="stat-value" style="color:var(--success)">${r.added?.length || 0}</div><div class="stat-label">Added</div></div>
                    <div class="stat-card"><div class="stat-value" style="color:var(--error)">${r.removed?.length || 0}</div><div class="stat-label">Removed</div></div>
                    <div class="stat-card"><div class="stat-value" style="color:var(--warning)">${r.changed?.length || 0}</div><div class="stat-label">Changed</div></div>
                `;

                const all = [
                    ...(r.added || []).map(p => ({ ...p, changeType: 'Added' })),
                    ...(r.removed || []).map(p => ({ ...p, changeType: 'Removed' })),
                    ...(r.changed || []).map(c => ({
                        changeType: 'Changed',
                        category: (c.new || c.old || {}).category || '',
                        targetPath: (c.new || c.old || {}).targetPath || '',
                        principalEntraUpn: (c.new || c.old || {}).principalEntraUpn || '',
                        principalSysName: (c.new || c.old || {}).principalSysName || '',
                        principalRole: (c.new || c.old || {}).principalRole || '',
                        through: (c.changedFields || []).join(', ')
                    }))
                ];

                document.getElementById('compareTable').innerHTML = all.length === 0
                    ? '<div class="empty-state"><p>No differences found</p></div>'
                    : `<table>
                        <thead><tr><th>Change</th><th>Category</th><th>Target</th><th>Principal</th><th>Role</th><th>Details</th></tr></thead>
                        <tbody>${all.slice(0, 500).map(c => {
                            const principal = c.principalEntraUpn || c.principalSysName || '';
                            return `<tr class="clickable-row" onclick="window.m365.showCompareDetail(this)" data-json="${escapeAttr(JSON.stringify(c))}">
                                <td style="color:var(--${c.changeType === 'Added' ? 'success' : c.changeType === 'Removed' ? 'error' : 'warning'})">${c.changeType}</td>
                                <td>${escapeHtml(c.category || '')}</td>
                                <td title="${escapeHtml(c.targetPath || '')}">${escapeHtml(truncate(c.targetPath, 40))}</td>
                                <td>${escapeHtml(principal)}</td>
                                <td>${escapeHtml(c.principalRole || '')}</td>
                                <td>${escapeHtml(c.through || '')}</td>
                            </tr>`;
                        }).join('')}</tbody>
                    </table>`;
            } catch (e) {
                showToast('Compare failed: ' + e.message, 'error');
            }
        },

        showCompareDetail(row) {
            try {
                const entry = JSON.parse(row.dataset.json);
                showDetailPanel(entry);
            } catch { }
        },

        async saveSettings() {
            try {
                const config = {
                    guiPort: parseInt(document.getElementById('cfgGuiPort').value),
                    maxThreads: parseInt(document.getElementById('cfgMaxThreads').value),
                    outputFormat: document.getElementById('cfgOutputFormat').value,
                    logLevel: document.getElementById('cfgLogLevel').value,
                    defaultTimeoutMinutes: parseInt(document.getElementById('cfgTimeout').value)
                };
                const res = await api.put('/config', config);
                if (res.success) showToast('Settings saved', 'success');
                else showToast(res.error || 'Save failed', 'error');
            } catch (e) {
                showToast('Error: ' + e.message, 'error');
            }
        },

        async resetDatabase() {
            showModal('Reset Database', `
                <p style="margin-bottom:12px">This will <strong>permanently delete</strong> all scans, permissions, logs, and audit entries.</p>
                <p style="margin-bottom:16px;color:var(--text-muted)">Settings and policies will be preserved.</p>
                <div style="display:flex;gap:8px;justify-content:flex-end">
                    <button class="btn btn-secondary" onclick="document.getElementById('modalOverlay').style.display='none'">Cancel</button>
                    <button class="btn btn-danger" id="confirmResetBtn" onclick="window.m365._confirmResetDatabase()">🗑️ Confirm Reset</button>
                </div>
            `);
        },

        async _confirmResetDatabase() {
            const btn = document.getElementById('confirmResetBtn');
            if (btn) { btn.disabled = true; btn.textContent = 'Resetting...'; }
            try {
                const res = await api.post('/database/reset');
                closeModal();
                if (res.success) {
                    showToast('Database reset successfully', 'success');
                    renderSettings(); // Refresh to show new sizes
                } else {
                    showToast(res.error || 'Reset failed', 'error');
                }
            } catch (e) {
                closeModal();
                showToast('Error: ' + e.message, 'error');
            }
        },

        applyQuickFilter,

        async clearFilters() {
            resetTableState();
            // Remove active state from quick filter pills
            document.querySelectorAll('#quickFilters .btn-active').forEach(b => b.classList.remove('btn-active'));
            currentPage = 1;
            await loadFilterOptions();
            await loadResults();
        },

        async editScanNotes(scanId) {
            const notes = prompt('Edit scan notes:');
            if (notes === null) return;
            try {
                const res = await api.put(`/scans/${scanId}`, { notes: notes, tags: '' });
                if (res.success) {
                    const el = document.getElementById(`scanNotes${scanId}`);
                    if (el) el.textContent = notes || '—';
                    showToast('Scan notes updated', 'success');
                } else {
                    showToast(res.error || 'Failed to update notes', 'error');
                }
            } catch (e) {
                showToast('Failed to update notes: ' + e.message, 'error');
            }
        },

        showPolicyForm(policy) {
            const isEdit = !!policy;
            const title = isEdit ? 'Edit Policy' : 'New Policy';
            const formHtml = `
                <input type="hidden" id="policyId" value="">
                <div class="form-group">
                    <label>Name</label>
                    <input id="policyName" type="text" placeholder="e.g. Full Control anonymous access">
                </div>
                <div class="form-group">
                    <label>Description</label>
                    <input id="policyDesc" type="text" placeholder="Describe what this rule flags">
                </div>
                <div style="display:flex;gap:12px;flex-wrap:wrap">
                    <div class="form-group" style="flex:1;min-width:120px">
                        <label>Severity</label>
                        <select id="policySeverity">
                            <option value="Critical">Critical</option>
                            <option value="High" selected>High</option>
                            <option value="Medium">Medium</option>
                            <option value="Low">Low</option>
                            <option value="Info">Info</option>
                        </select>
                    </div>
                    <div class="form-group" style="flex:1;min-width:120px">
                        <label>Category filter (empty = all)</label>
                        <input id="policyCat" type="text" placeholder="e.g. SharePoint,Entra">
                    </div>
                </div>
                <div class="form-group">
                    <label>Conditions <span style="color:var(--text-muted);font-weight:400">(all conditions must match)</span></label>
                    <div id="conditionsEditor"></div>
                </div>
                <div class="btn-group">
                    <button class="btn btn-primary" onclick="window.m365.savePolicy()">💾 Save</button>
                    <button class="btn btn-secondary" onclick="document.getElementById('modalOverlay').style.display='none'">Cancel</button>
                </div>
            `;
            showModal(title, formHtml);
            if (isEdit) {
                document.getElementById('policyId').value = policy.id;
                document.getElementById('policyName').value = policy.name;
                document.getElementById('policyDesc').value = policy.description || '';
                document.getElementById('policySeverity').value = policy.severity;
                document.getElementById('policyCat').value = policy.categoryFilter || '';
                policyConditions = (policy.conditions || []).map(c => ({...c}));
                if (policyConditions.length === 0) policyConditions.push({ field: 'principal_type', operator: 'equals', value: '' });
            } else {
                policyConditions = [{ field: 'principal_type', operator: 'equals', value: '' }];
            }
            renderConditionsEditor();
        },

        addCondition() {
            policyConditions = collectConditions();
            policyConditions.push({ field: 'principal_type', operator: 'equals', value: '' });
            renderConditionsEditor();
        },

        removeCondition(idx) {
            policyConditions = collectConditions();
            policyConditions.splice(idx, 1);
            if (policyConditions.length === 0) policyConditions.push({ field: 'principal_type', operator: 'equals', value: '' });
            renderConditionsEditor();
        },

        async editPolicy(id) {
            try {
                const res = await api.get('/policies');
                if (res.success) {
                    const policy = res.data.find(p => p.id === id);
                    if (policy) window.m365.showPolicyForm(policy);
                }
            } catch { }
        },

        async togglePolicy(id, enabled) {
            try {
                const res = await api.put(`/policies/${id}`, { enabled });
                if (res.success) await loadPolicies();
                else showToast(res.error || 'Toggle failed', 'error');
            } catch (e) { showToast('Error: ' + e.message, 'error'); }
        },

        async savePolicy() {
            const id = document.getElementById('policyId').value;
            const conditions = collectConditions().filter(c => c.value.trim() !== '');
            const policy = {
                name: document.getElementById('policyName').value,
                description: document.getElementById('policyDesc').value,
                enabled: true,
                severity: document.getElementById('policySeverity').value,
                categoryFilter: document.getElementById('policyCat').value,
                conditions: conditions
            };
            if (!policy.name) { showToast('Policy name is required', 'error'); return; }
            if (conditions.length === 0) { showToast('At least one condition with a value is required', 'error'); return; }

            try {
                let res;
                if (id) {
                    res = await api.put(`/policies/${id}`, policy);
                } else {
                    res = await api.post('/policies', policy);
                }
                if (res.success) {
                    showToast(id ? 'Policy updated' : 'Policy created', 'success');
                    closeModal();
                    await loadPolicies();
                } else {
                    showToast(res.error || 'Save failed', 'error');
                }
            } catch (e) {
                showToast('Error: ' + e.message, 'error');
            }
        },

        async deletePolicy(id) {
            if (!confirm('Delete this policy?')) return;
            try {
                const res = await fetch(`/api/policies/${id}`, { method: 'DELETE' });
                const data = await res.json();
                if (data.success) {
                    showToast('Policy deleted', 'success');
                    await loadPolicies();
                } else {
                    showToast(data.error || 'Delete failed', 'error');
                }
            } catch (e) {
                showToast('Error: ' + e.message, 'error');
            }
        },

        async resetDefaultPolicies() {
            if (!confirm('This will delete all default policies and re-create them from built-in definitions. Custom policies will not be affected. Continue?')) return;
            try {
                const res = await api.post('/policies/reset-defaults', {});
                if (res.success) {
                    showToast('Default policies have been reset', 'success');
                    await loadPolicies();
                } else {
                    showToast(res.error || 'Reset failed', 'error');
                }
            } catch (e) {
                showToast('Error: ' + e.message, 'error');
            }
        },

        async evaluatePolicies() {
            const btn = document.getElementById('evalPoliciesBtn');
            if (btn) {
                btn.disabled = true;
                btn.innerHTML = '<span class="btn-spinner"></span> Evaluating...';
            }
            try {
                const scans = await api.get('/scans' + tenantQuery());
                if (!scans.success || scans.data.length === 0) {
                    showToast('No scans available to evaluate', 'error');
                    return;
                }
                const latest = scans.data.find(s => s.status === 'Completed');
                if (!latest) { showToast('No completed scans found', 'error'); return; }

                const res = await api.post('/policies/evaluate', { scanId: latest.id });
                if (!res.success) { showToast(res.error || 'Evaluation failed', 'error'); return; }

                const violations = res.data.violations || {};
                lastEvalEntries = res.data.entries || {};

                const card = document.getElementById('violationsCard');
                const table = document.getElementById('violationsTable');
                card.style.display = '';

                const vEntries = Object.entries(violations);
                if (vEntries.length === 0) {
                    table.innerHTML = '<div class="empty-state"><p>✅ No policy violations found in the latest scan</p></div>';
                    showToast('Evaluation complete — no violations', 'success');
                    return;
                }

                const rows = vEntries.flatMap(([idx, viols]) =>
                    viols.map(v => {
                        const entry = lastEvalEntries[idx];
                        const principal = entry ? (entry.principalEntraUpn || entry.principalSysName || '') : '';
                        const target = entry ? entry.targetPath || '' : '';
                        return `<tr class="clickable-row" onclick="window.m365.showViolationDetail(${idx})">
                            <td><span class="risk-badge risk-${(v.severity || 'high').toLowerCase()}">${escapeHtml(v.severity)}</span></td>
                            <td>${escapeHtml(v.policyName)}</td>
                            <td style="max-width:250px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${escapeAttr(target)}">${escapeHtml(target)}</td>
                            <td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${escapeAttr(principal)}">${escapeHtml(principal)}</td>
                            <td>${escapeHtml(entry ? entry.principalRole || '' : '')}</td>
                        </tr>`;
                    })
                );
                table.innerHTML = `<table>
                    <thead><tr><th>Severity</th><th>Policy</th><th>Target</th><th>Principal</th><th>Role</th></tr></thead>
                    <tbody>${rows.join('')}</tbody>
                </table>
                <p style="margin-top:8px;font-size:0.85em;color:var(--text-muted)">${vEntries.length} entries with violations in scan #${latest.id}</p>`;
                showToast(`Evaluation complete — ${vEntries.length} violations found`, 'success');
            } catch (e) {
                showToast('Evaluation failed: ' + e.message, 'error');
            } finally {
                if (btn) {
                    btn.disabled = false;
                    btn.innerHTML = '▶ Evaluate Latest Scan';
                }
            }
        },

        showViolationDetail(idx) {
            const entry = lastEvalEntries[idx];
            if (!entry) { showToast('Entry details not available', 'error'); return; }
            const fields = [
                ['Category', entry.category],
                ['Target Path', entry.targetPath],
                ['Target Type', entry.targetType],
                ['Target ID', entry.targetId],
                ['Principal UPN', entry.principalEntraUpn],
                ['Principal Name', entry.principalSysName],
                ['Principal Type', entry.principalType],
                ['Principal Entra ID', entry.principalEntraId],
                ['Role', entry.principalRole],
                ['Through', entry.through],
                ['Access Type', entry.accessType],
                ['Tenure', entry.tenure],
                ['Risk Level', entry.riskLevel],
                ['Risk Reason', entry.riskReason],
            ].filter(([, v]) => v);
            const html = `<table class="detail-table">
                <tbody>${fields.map(([label, value]) =>
                    `<tr><td class="detail-label">${escapeHtml(label)}</td><td>${escapeHtml(value)}</td></tr>`
                ).join('')}</tbody>
            </table>`;
            showModal('Permission Entry Detail', html);
        },

        toggleColumnPicker() {
            const picker = document.getElementById('columnPicker');
            if (!picker) return;
            if (picker.style.display !== 'none') { picker.style.display = 'none'; return; }
            const allCols = [
                { key: 'riskLevel', label: 'Risk' },
                { key: 'category', label: 'Category' },
                { key: 'targetPath', label: 'Target' },
                { key: 'targetType', label: 'Type' },
                { key: 'principal', label: 'Principal' },
                { key: 'principalType', label: 'Identity Type' },
                { key: 'principalRole', label: 'Role' },
                { key: 'through', label: 'Through' },
                { key: 'accessType', label: 'Access' }
            ];
            picker.innerHTML = allCols.map(c => `
                <label style="display:inline-flex;align-items:center;gap:4px;margin-right:12px;cursor:pointer">
                    <input type="checkbox" ${!hiddenColumns.has(c.key) ? 'checked' : ''} data-col-key="${c.key}">
                    ${escapeHtml(c.label)}
                </label>
            `).join('');
            picker.style.display = '';
            picker.querySelectorAll('input[type=checkbox]').forEach(cb => {
                cb.addEventListener('change', () => {
                    if (cb.checked) hiddenColumns.delete(cb.dataset.colKey);
                    else hiddenColumns.add(cb.dataset.colKey);
                    localStorage.setItem('m365pv2-hiddenCols', JSON.stringify([...hiddenColumns]));
                    loadResults();
                });
            });
        },

        loadResults,
        showGroupMembers,
        searchUserPerms
    };

    // ── Keyboard Shortcuts ──────────────────────────────────────
    document.addEventListener('keydown', (e) => {
        // Ignore if typing in an input/textarea/select
        if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT') {
            if (e.key === 'Escape') e.target.blur();
            return;
        }

        // Esc closes modals
        if (e.key === 'Escape') {
            closeModal();
            return;
        }

        // Ctrl+E or Cmd+E to export
        if ((e.ctrlKey || e.metaKey) && e.key === 'e') {
            e.preventDefault();
            window.m365.exportResults();
            return;
        }

        // Ctrl+K or Cmd+K to focus search
        if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
            e.preventDefault();
            const searchInput = document.getElementById('searchInput');
            if (searchInput) searchInput.focus();
            return;
        }
    });

    // ── Utilities ───────────────────────────────────────────────
    function escapeHtml(str) {
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    function escapeAttr(str) {
        return (str || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function truncate(str, max) {
        if (!str) return '';
        return str.length > max ? str.slice(0, max) + '…' : str;
    }

    function debounce(fn, ms) {
        let timer;
        return function (...args) {
            clearTimeout(timer);
            timer = setTimeout(() => fn.apply(this, args), ms);
        };
    }

    // ── Init ────────────────────────────────────────────────────
    async function init() {
        initTheme();
        await refreshStatus();
        window.addEventListener('hashchange', navigate);
        navigate();
        setInterval(refreshStatus, 10000);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
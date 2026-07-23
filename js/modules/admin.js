// js/modules/admin.js

export function updateFilterChipsUI() {
  const chipRegion = document.getElementById("chip-filter-region");
  const chipZone = document.getElementById("chip-filter-zone");
  const chipGroup = document.getElementById("chip-filter-group");

  if (chipRegion) {
    if (state.adminFilters.region) {
      chipRegion.classList.add("active");
      chipRegion.innerHTML = `<span>${state.adminFilters.region}</span> <span class="chip-clear" data-clear="region">ï¿½ï¿½ï¿½</span>`;
    } else {
      chipRegion.classList.remove("active");
      chipRegion.innerHTML = `<span>ï¿½ï¿½å¸ï¿½å¸ä¹ï¿½ï¿½ï¿½</span> <span class="chip-arrow">ï¿½ï¿½ï¿½</span>`;
    }
  }

  if (chipZone) {
    if (state.adminFilters.zone) {
      chipZone.classList.add("active");
      chipZone.innerHTML = `<span>${state.adminFilters.zone}</span> <span class="chip-clear" data-clear="zone">ï¿½ï¿½ï¿½</span>`;
    } else {
      chipZone.classList.remove("active");
      chipZone.innerHTML = `<span>ï¿½ï¿½å¸ï¿½å½ï¿½æ¹ï¿½ï¿½</span> <span class="chip-arrow">ï¿½ï¿½ï¿½</span>`;
    }
  }

  if (chipGroup) {
    if (state.adminFilters.group) {
      chipGroup.classList.add("active");
      chipGroup.innerHTML = `<span>${state.adminFilters.group}</span> <span class="chip-clear" data-clear="group">ï¿½ï¿½ï¿½</span>`;
    } else {
      chipGroup.classList.remove("active");
      chipGroup.innerHTML = `<span>ï¿½ï¿½å¸ï¿½å¸ï¿½ï¿½è¯ï¿½</span> <span class="chip-arrow">ï¿½ï¿½ï¿½</span>`;
    }
  }
}

export function openAdminFilterBottomSheet(type) {
  const overlay = document.getElementById("global-bottom-sheet");
  const titleEl = document.getElementById("bottom-sheet-title");
  const listEl = document.getElementById("bottom-sheet-list");
  if (!overlay || !listEl) return;

  let title = "ï¿½ï¿½è±¢ï¿½ï¿½è­æï¿½è±¢ï¿½ï¿½éï¿½";
  let options = [];
  let selectedValue = state.adminFilters[type];

  const getPredefinedRegions = () => {
    return (state.orgStructure && state.orgStructure.regions && state.orgStructure.regions.length > 0)
      ? state.orgStructure.regions
      : ["ï¿½ï¿½åï¿½ï¿½", "ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½", "é¼è¸¹ï¿½ï¿½", "ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½", "ï¿½ï¿½ï¿½æ ï¿½æï¿½", "ï¿½ï¿½åï¿½ï¿½", "ï¿½ï¿½èï¿½ï¿½"];
  };

  const getPredefinedZones = () => {
    if (state.adminFilters.region) {
      return state.orgStructure.zones[state.adminFilters.region] || [];
    }
    const all = [];
    if (state.orgStructure && state.orgStructure.zones) {
      Object.values(state.orgStructure.zones).forEach(arr => {
        if (Array.isArray(arr)) all.push(...arr);
      });
    }
    return Array.from(new Set(all));
  };

  const getPredefinedGroups = () => {
    if (state.adminFilters.zone) {
      return state.orgStructure.groups[state.adminFilters.zone] || [];
    }
    const all = [];
    if (state.orgStructure && state.orgStructure.groups) {
      Object.values(state.orgStructure.groups).forEach(arr => {
        if (Array.isArray(arr)) all.push(...arr);
      });
    }
    return Array.from(new Set(all));
  };

  if (type === "region") {
    title = "ï¿½ï¿½è±¢ï¿½ï¿½æ­æ¹ï¿½ï¿½";
    options = getPredefinedRegions();
  } else if (type === "zone") {
    title = "ï¿½ï¿½è±¢ï¿½ï¿½ï¿½ï¿½æ¹ï¿½ï¿½";
    options = getPredefinedZones();
  } else if (type === "group") {
    title = "ï¿½ï¿½è±¢ï¿½ï¿½æ ï¿½è¯ï¿½";
    options = getPredefinedGroups();
  }

  if (titleEl) titleEl.textContent = title;
  listEl.innerHTML = "";

  const allBtn = document.createElement("button");
  allBtn.className = `bottom-sheet-item ${!selectedValue ? "selected" : ""}`;
  allBtn.type = "button";
  allBtn.textContent = `ï¿½ï¿½å¸ï¿½ï¿½${type === "region" ? "æ­æ¹ï¿½ï¿½" : (type === "zone" ? "ï¿½ï¿½æ¹ï¿½ï¿½" : "æ ï¿½è¯ï¿½")}`;
  allBtn.onclick = () => {
    console.log(`ï¿½ï¿½ï¿½ï¿½ [Debug] Bottom Sheet ï¿½ï¿½è±¢ï¿½ï¿½çï¿½ï¿½ï¿½æ¤ç¥ï¿½ï¿½ï¿½: ï¿½ï¿½å¸ï¿½ï¿½${type}`);
    state.adminFilters[type] = null;
    if (type === "region") {
      state.adminFilters.zone = null;
      state.adminFilters.group = null;
    } else if (type === "zone") {
      state.adminFilters.group = null;
    }
    updateFilterChipsUI();
    closeAdminFilterBottomSheet();
    renderAdminUserManagement();
  };
  listEl.appendChild(allBtn);

  options.forEach(opt => {
    const btn = document.createElement("button");
    btn.className = `bottom-sheet-item ${selectedValue === opt ? "selected" : ""}`;
    btn.type = "button";
    btn.textContent = opt;
    btn.onclick = () => {
      console.log(`ï¿½ï¿½ï¿½ï¿½ [Debug] Bottom Sheet ï¿½ï¿½è±¢ï¿½ï¿½è­æï¿½è±¢ï¿½ï¿½éï¿½: ${type} = ${opt}`);
      state.adminFilters[type] = opt;
      if (type === "region") {
        state.adminFilters.zone = null;
        state.adminFilters.group = null;
      } else if (type === "zone") {
        state.adminFilters.group = null;
      }
      updateFilterChipsUI();
      closeAdminFilterBottomSheet();
      renderAdminUserManagement();
    };
    listEl.appendChild(btn);
  });

  overlay.classList.add("active");
}

export function closeAdminFilterBottomSheet() {
  console.log("ï¿½ï¿½ï¿½ï¿½ [Debug] ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½èâ ï¿½ï¿½è­æï¿½ï¿½ Bottom Sheet");
  const overlay = document.getElementById("global-bottom-sheet");
  if (overlay) overlay.classList.remove("active");
}

export function initAdminFiltersUI() {
  ["region", "zone", "group"].forEach(type => {
    const chip = document.getElementById(`chip-filter-${type}`);
    if (chip) {
      chip.onclick = (e) => {
        e.preventDefault();
        const clearBtn = e.target.closest(".chip-clear");
        if (clearBtn) {
          console.log(`ï¿½ï¿½ï¿½ [Debug] çï¿½ï¿½ï¿½æ¤ç¥ï¿½ï¿½è±¢ï¿½ï¿½èæï¿½ï¿½ï¿½ï¿½ï¿½æºï¿½ï¿½ï¿½ï¿½: ${type}`);
          e.stopPropagation();
          state.adminFilters[type] = null;
          if (type === "region") {
            state.adminFilters.zone = null;
            state.adminFilters.group = null;
          } else if (type === "zone") {
            state.adminFilters.group = null;
          }
          updateFilterChipsUI();
          renderAdminUserManagement();
        } else {
          console.log(`ï¿½ï¿½ï¿½ï¿½ [Debug] è­æï¿½è±¢ï¿½ï¿½èæ¹ï¿½ï¿½ï¿½ï¿½ï¿½æºï¿½ï¿½ï¿½ï¿½åï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ Bottom Sheet: ${type}`);
          openAdminFilterBottomSheet(type);
        }
      };
    }
  });

  const closeBtn = document.getElementById("btn-close-bottom-sheet");
  if (closeBtn) {
    closeBtn.onclick = (e) => {
      console.log("ï¿½ï¿½ï¿½ï¿½ [Debug] ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ Bottom Sheet ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½æºï¿½ï¿½ï¿½ï¿½");
      e.preventDefault();
      closeAdminFilterBottomSheet();
    };
  }

  const overlay = document.getElementById("global-bottom-sheet");
  if (overlay) {
    overlay.onclick = (e) => {
      if (e.target === overlay) {
        console.log("ï¿½ï¿½ï¿½ï¿½ [Debug] æºï¿½ï¿½ï¿½ï¿½ Bottom Sheet æ­ï¿½ï¿½ï¿½å¸ï¿½æ¡èï¿½ï¿½ï¿½ï¿½ï¿½ï¿½");
        closeAdminFilterBottomSheet();
      }
    };
  }

  updateFilterChipsUI();
}

export async function renderAdminUserManagement() {
  const listContainer = document.getElementById("admin-users-list");
  if (!listContainer) return;

  const searchInput = document.getElementById("admin-search-user");
  const query = searchInput ? searchInput.value.trim().toLowerCase() : "";

  ComponentSkeletonLoader.show('members', listContainer);

  try {
    const users = await db.fetchMergedUsersList(null, true);
    
    const roleOrder = { admin: 1, great_zone_leader: 2, zone_leader: 3, group_leader: 4, member: 5 };
    const sortedUsers = [...users].sort((a, b) => {
      if (a.name === state.currentUser.name) return -1;
      if (b.name === state.currentUser.name) return 1;
      return (roleOrder[a.role] || 99) - (roleOrder[b.role] || 99);
    });

    const filteredUsers = sortedUsers.filter(u => {
      const matchName = u.name.toLowerCase().includes(query);
      const matchEmail = u.email ? u.email.toLowerCase().includes(query) : false;
      const matchRegion = !state.adminFilters.region || u.great_region === state.adminFilters.region;
      const matchZone = !state.adminFilters.zone || u.pastoral_zone === state.adminFilters.zone;
      const matchGroup = !state.adminFilters.group || u.small_group === state.adminFilters.group;
      return (matchName || matchEmail) && matchRegion && matchZone && matchGroup;
    });

    listContainer.innerHTML = "";

    if (filteredUsers.length === 0) {
      listContainer.innerHTML = `<div style="text-align: center; padding: 2.5rem; color: var(--text-muted);">ï¿½ï¿½â ï¿½è²æ³µï¿½ï¿½ï¿½ï¿½ï¿½ï¿½</div>`;
      return;
    }

    const roleLabels = {
      member: "éï¿½ï¿½ï¿½ç¥ï¿½ï¿½ï¿½ï¿½ï¿½",
      group_leader: "æ ï¿½è¯ï¿½ï¿½ï¿½ï¿½",
      zone_leader: "ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½",
      great_zone_leader: "æ­æ¹ï¿½ï¿½ï¿½ï¿½ï¿½",
      admin: "èé¤çµèâ ï¿½ï¿½ï¿½ï¿½ï¿½"
    };

    filteredUsers.forEach(user => {
      const roleLabel = roleLabels[user.role] || user.role;
      
      const item = document.createElement("div");
      item.className = "member-list-item";
      
      item.innerHTML = `
        <div class="member-info-left">
          <div class="member-name-row">
            <span class="member-name-text">${escapeHTML(user.name)}</span>
            <span class="role-badge-pill">${escapeHTML(roleLabel)}</span>
          </div>
          <div class="member-sub-text">
            ${escapeHTML(user.great_region)} / ${escapeHTML(user.pastoral_zone)} / ${escapeHTML(user.small_group)}
          </div>
          ${user.email ? `<div class="member-email-text">${escapeHTML(user.email)}</div>` : ''}
        </div>
        <div class="member-arrow-right">
          ${typeof renderIcon === "function" ? renderIcon("chevronRight", { size: "sm", className: "nlc-icon" }) : ""}
        </div>
      `;

      item.onclick = (e) => {
        e.preventDefault();
        openMemberEditBottomSheet(user);
      };

      listContainer.appendChild(item);
    });

  } catch (err) {
    console.error("Failed to render admin user management:", err);
    listContainer.innerHTML = `<div class="text-danger" style="text-align: center; padding: 2.5rem;">é ï¿½ï¿½ï¿½äºä»ï¿½ï¿½ï¿½: ${err.message || err}</div>`;
  }
}

export function openMemberEditBottomSheet(user) {
  const overlay = document.getElementById("global-bottom-sheet");
  const titleEl = document.getElementById("bottom-sheet-title");
  const listEl = document.getElementById("bottom-sheet-list");
  if (!overlay || !listEl) return;

  if (titleEl) titleEl.textContent = `èâ ï¿½ï¿½ ${user.name} ï¿½ï¿½ï¿½çï¿½ï¿½ï¿½ï¿½`;
  listEl.innerHTML = "";

  const roleOptions = [
    { value: "member", label: "éï¿½ï¿½ï¿½ç¥ï¿½ï¿½ï¿½ï¿½ï¿½" },
    { value: "group_leader", label: "æ ï¿½è¯ï¿½ï¿½ï¿½ï¿½" },
    { value: "zone_leader", label: "ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½" },
    { value: "great_zone_leader", label: "æ­æ¹ï¿½ï¿½ï¿½ï¿½ï¿½" },
    { value: "admin", label: "èé¤çµèâ ï¿½ï¿½ï¿½ï¿½ï¿½" }
  ];



  const isLeader = ["great_zone_leader", "zone_leader", "group_leader"].includes(user.role);
  if (isLeader) {
    const scopeBtn = document.createElement("button");
    scopeBtn.className = "bottom-sheet-item";
    scopeBtn.style.background = "var(--color-brand-subtle, rgba(4,169,210,0.12))";
    scopeBtn.style.borderColor = "var(--color-brand-border, rgba(4,169,210,0.24))";
    scopeBtn.style.color = "#a5b4fc";
    scopeBtn.style.marginBottom = "0.8rem";
    scopeBtn.type = "button";

    let scopeDesc = "";
    if (user.role === "great_zone_leader") scopeDesc = user.managed_regions || user.great_region || "ï¿½ï¿½è¾èº«æ°ï¿½";
    else if (user.role === "zone_leader") scopeDesc = user.managed_zones || user.pastoral_zone || "ï¿½ï¿½è¾èº«æ°ï¿½";
    else if (user.role === "group_leader") scopeDesc = user.managed_groups || user.small_group || "ï¿½ï¿½è¾èº«æ°ï¿½";

    scopeBtn.innerHTML = iconLabel("edit", `é½æ ¼ï¿½å¯§æ£é §ï¿½è­ï¿½ï¿½ï¿½ï¿½ (${scopeDesc})`);
    scopeBtn.onclick = async () => {
      console.log(`ï¿½ï¿½ï¿½å­ï¿½ [Debug] é½æ ¼ï¿½å¯§æ£é §ï¿½è­ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½é¡æï¿½ï¿½ï¿½ï¿½ï¿½åï¿½ï¿½ï¿½ï¿½ï¿½ï¿½â´ï¿½ï¿½${user.name}`);
      closeAdminFilterBottomSheet();
      const resp = await showResponsibilityModal(user.role, user);
      if (!resp) return;

      loader.show();
      const success = await db.updateUserRole(user.id, user.role, user.name, resp);
      loader.hide();

      if (success) {
        user.managed_regions = resp.managed_regions;
        user.managed_zones = resp.managed_zones;
        user.managed_groups = resp.managed_groups;

        if (user.name === state.currentUser.name) {
          state.currentUser.managed_regions = resp.managed_regions;
          state.currentUser.managed_zones = resp.managed_zones;
          state.currentUser.managed_groups = resp.managed_groups;
          if (typeof renderProfileView === "function") renderProfileView();
        }
        alert("æè«ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½æ¹ï¿½åæ£é §ï¿½è­ï¿½ï¿½ï¿½ï¿½åï¿½");
        renderAdminUserManagement();
      } else {
        alert("ï¿½ï¿½æ¹ï¿½åæ£é §ï¿½è­ï¿½ï¿½ï¿½ï¿½æ­æï¿½ï¿½åï¿½é¢ï¿½ï¿½ï¿½ï¿½é°è¾ï¿½ï¿½");
      }
    };
    listEl.appendChild(scopeBtn);
  }

  const headerText = document.createElement("div");
  headerText.style.fontSize = "0.75rem";
  headerText.style.color = "var(--text-secondary)";
  headerText.style.margin = "0.2rem 0 0.5rem 0.2rem";
  headerText.style.fontWeight = "bold";
  headerText.textContent = "éï¿½ï¿½ï¿½æ¸²ï¿½ï¿½ï¿½ï¿½è°æ¾ï¿½ï¿½ï¿½åï¿½";
  listEl.appendChild(headerText);

  roleOptions.forEach(opt => {
    const btn = document.createElement("button");
    const isSelected = user.role === opt.value;
    btn.className = `bottom-sheet-item ${isSelected ? "selected" : ""}`;
    btn.type = "button";
    btn.textContent = opt.label;
    btn.onclick = async () => {
      console.log(`ï¿½ï¿½ï¿½å­ï¿½ [Debug] éï¿½ï¿½ï¿½æ¸²ï¿½ï¿½ï¿½ï¿½è°æ¾ï¿½ï¿½ï¿½æºï¿½ï¿½ï¿½ï¿½: ${user.name} -> ${opt.label}`);
      closeAdminFilterBottomSheet();
      if (isSelected) return;

      let additionalFields = {};
      if (["great_zone_leader", "zone_leader", "group_leader"].includes(opt.value)) {
        const resp = await showResponsibilityModal(opt.value, user);
        if (!resp) return;
        additionalFields = resp;
      }

      loader.show();
      const success = await db.updateUserRole(user.id, opt.value, user.name, additionalFields);
      loader.hide();

      if (success) {
        user.role = opt.value;
        if (additionalFields.managed_regions !== undefined) user.managed_regions = additionalFields.managed_regions;
        if (additionalFields.managed_zones !== undefined) user.managed_zones = additionalFields.managed_zones;
        if (additionalFields.managed_groups !== undefined) user.managed_groups = additionalFields.managed_groups;

        if (user.name === state.currentUser.name) {
          state.currentUser.role = opt.value;
          state.realRole = opt.value;
          if (additionalFields.managed_regions !== undefined) state.currentUser.managed_regions = additionalFields.managed_regions;
          if (additionalFields.managed_zones !== undefined) state.currentUser.managed_zones = additionalFields.managed_zones;
          if (additionalFields.managed_groups !== undefined) state.currentUser.managed_groups = additionalFields.managed_groups;
          if (typeof renderProfileView === "function") renderProfileView();
        }
        alert("æè«ï¿½ï¿½ï¿½ï¿½ï¿½éï¿½ï¿½ï¿½æ¹ï¿½ï¿½ï¿½ï¿½â¥ï¿½ï¿½ï¿½ï¿½ï¿½é«ï¿½ï¿½ï¿½èï¿½ï¿½");
        renderAdminUserManagement();
      } else {
        alert("éï¿½ï¿½ï¿½æ¸²ï¿½ï¿½ï¿½ï¿½è£ä»ï¿½ï¿½ï¿½åï¿½é¢ï¿½ï¿½ï¿½ï¿½é°è¾ï¿½ï¿½");
      }
    };
    listEl.appendChild(btn);
  });

  overlay.classList.add("active");
}

export function initAdminOrgManagement() {
  const regionSelect = document.getElementById("admin-org-region");
  const zoneSelect = document.getElementById("admin-org-zone");
  const groupSelect = document.getElementById("admin-org-group");

  if (!regionSelect || !zoneSelect || !groupSelect) return;

  regionSelect.onchange = () => {
    populateAdminZones();
  };

  zoneSelect.onchange = () => {
    populateAdminGroups();
  };

  document.getElementById("admin-add-region-btn").onclick = async () => {
    const name = prompt("請輸入新大區名稱", "台北大區");
    if (name && name.trim()) {
      loader.show("建立中...");
      const success = await db.createGreatRegion(name.trim());
      loader.hide();
      if (success) {
        alert("大區建立成功");
        renderAdminOrgManagement();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-edit-region-btn").onclick = async () => {
    const val = regionSelect.value;
    if (!val) { showToast("請選擇大區"); return; }
    const opt = regionSelect.options[regionSelect.selectedIndex];
    const oldName = opt.text;
    const newName = prompt(`修改大區 ${oldName} 名稱`, oldName);
    if (newName && newName.trim() && newName.trim() !== oldName) {
      loader.show("修改中...");
      const success = await db.updateGreatRegion(val, newName.trim());
      loader.hide();
      if (success) {
        showToast("修改成功");
        populateAdminRegions();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-delete-region-btn").onclick = async () => {
    const val = regionSelect.value;
    if (!val) {
      showToast("請選擇要刪除的大區");
      return;
    }
    const opt = regionSelect.options[regionSelect.selectedIndex];
    const confirmed = await window.showConfirmDialog({
      title: "刪除大區確認",
      message: `確定要刪除大區「${opt.text}」嗎？此操作將同時刪除該大區下屬的所有牧區與小組！`,
      confirmText: "確定刪除",
      cancelText: "取消",
      isDestructive: true
    });
    if (confirmed) {
      loader.show("刪除中...");
      const success = await db.deleteGreatRegion(val);
      loader.hide();
      if (success) {
        showToast("大區刪除成功");
        renderAdminOrgManagement();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-add-zone-btn").onclick = async () => {
    const regionVal = regionSelect.value;
    if (!regionVal) {
      showToast("請先選擇大區");
      return;
    }
    const name = prompt("請輸入新牧區名稱", "第一牧區");
    if (name && name.trim()) {
      loader.show("建立中...");
      const success = await db.createPastoralZone(name.trim(), regionVal);
      loader.hide();
      if (success) {
        showToast("牧區建立成功");
        populateAdminZones();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-edit-zone-btn").onclick = async () => {
    const val = zoneSelect.value;
    if (!val) {
      showToast("請選擇要修改的牧區");
      return;
    }
    const opt = zoneSelect.options[zoneSelect.selectedIndex];
    const oldName = opt.text;
    const newName = prompt(`修改牧區 ${oldName} 名稱`, oldName);
    if (newName && newName.trim() && newName.trim() !== oldName) {
      loader.show("修改中...");
      const success = await db.updatePastoralZone(val, newName.trim());
      loader.hide();
      if (success) {
        showToast("修改成功");
        populateAdminZones();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-delete-zone-btn").onclick = async () => {
    const val = zoneSelect.value;
    if (!val) {
      showToast("請選擇要刪除的牧區");
      return;
    }
    const opt = zoneSelect.options[zoneSelect.selectedIndex];
    const confirmed = await window.showConfirmDialog({
      title: "刪除牧區確認",
      message: `確定要刪除牧區「${opt.text}」嗎？此操作將同時刪除該牧區下屬的所有小組！`,
      confirmText: "確定刪除",
      cancelText: "取消",
      isDestructive: true
    });
    if (confirmed) {
      loader.show("刪除中...");
      const success = await db.deletePastoralZone(val);
      loader.hide();
      if (success) {
        showToast("牧區刪除成功");
        populateAdminZones();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-add-group-btn").onclick = async () => {
    const zoneVal = zoneSelect.value;
    if (!zoneVal) {
      showToast("請先選擇牧區");
      return;
    }
    const name = prompt("請輸入新小組名稱", "第一小組");
    if (name && name.trim()) {
      loader.show("建立中...");
      const success = await db.createSmallGroup(name.trim(), zoneVal);
      loader.hide();
      if (success) {
        showToast("小組建立成功");
        populateAdminGroups();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-edit-group-btn").onclick = async () => {
    const val = groupSelect.value;
    if (!val) {
      showToast("請選擇要修改的小組");
      return;
    }
    const opt = groupSelect.options[groupSelect.selectedIndex];
    const oldName = opt.text;
    const newName = prompt(`修改小組 ${oldName} 名稱`, oldName);
    if (newName && newName.trim() && newName.trim() !== oldName) {
      loader.show("修改中...");
      const success = await db.updateSmallGroup(val, newName.trim());
      loader.hide();
      if (success) {
        showToast("修改成功");
        populateAdminGroups();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };

  document.getElementById("admin-delete-group-btn").onclick = async () => {
    const val = groupSelect.value;
    if (!val) {
      showToast("請選擇要刪除的小組");
      return;
    }
    const opt = groupSelect.options[groupSelect.selectedIndex];
    const confirmed = await window.showConfirmDialog({
      title: "刪除小組確認",
      message: `確定要刪除小組「${opt.text}」嗎？此操作將刪除該小組的所有讀經狀態！`,
      confirmText: "確定刪除",
      cancelText: "取消",
      isDestructive: true
    });
    if (confirmed) {
      loader.show("刪除中...");
      const success = await db.deleteSmallGroup(val);
      loader.hide();
      if (success) {
        showToast("小組刪除成功");
        populateAdminGroups();
        if (typeof renderProfileView === "function") renderProfileView();
      }
    }
  };
}

export function renderAdminOrgManagement() {
  const regionSelect = document.getElementById("admin-org-region");
  const zoneSelect = document.getElementById("admin-org-zone");
  const groupSelect = document.getElementById("admin-org-group");

  if (!regionSelect || !zoneSelect || !groupSelect) return;

  regionSelect.innerHTML = `<option value="">-- é¢ï¿½ï¿½ï¿½è±¢ï¿½ï¿½æ­æ¹ï¿½ï¿½ --</option>`;
  if (state.isSupabaseMode && state.orgStructure.rawRegions) {
    state.orgStructure.rawRegions.forEach(r => {
      regionSelect.innerHTML += `<option value="${r.id}">${r.name}</option>`;
    });
  } else {
    state.orgStructure.regions.forEach(rName => {
      regionSelect.innerHTML += `<option value="${rName}">${rName}</option>`;
    });
  }

  zoneSelect.innerHTML = `<option value="">-- é¢ï¿½ï¿½ï¿½è±¢ï¿½ï¿½æ­æ¹ï¿½ï¿½æºï¿½é ï¿½ï¿½ï¿½ï¿½ --</option>`;
  groupSelect.innerHTML = `<option value="">-- é¢ï¿½ï¿½ï¿½è±¢ï¿½ï¿½ï¿½ï¿½æ¹ï¿½ï¿½æºï¿½é ï¿½ï¿½ï¿½ï¿½ --</option>`;
}

export function populateAdminZones() {
  const regionSelect = document.getElementById("admin-org-region");
  const zoneSelect = document.getElementById("admin-org-zone");
  const groupSelect = document.getElementById("admin-org-group");

  zoneSelect.innerHTML = `<option value="">-- é¢ï¿½ï¿½ï¿½è±¢ï¿½ï¿½ï¿½ï¿½æ¹ï¿½ï¿½ --</option>`;
  groupSelect.innerHTML = `<option value="">-- é¢ï¿½ï¿½ï¿½è±¢ï¿½ï¿½ï¿½ï¿½æ¹ï¿½ï¿½æºï¿½é ï¿½ï¿½ï¿½ï¿½ --</option>`;

  const regionVal = regionSelect.value;
  if (!regionVal) return;

  if (state.isSupabaseMode && state.orgStructure.rawZones) {
    const regionZones = state.orgStructure.rawZones.filter(z => z.great_region_id === regionVal);
    regionZones.forEach(z => {
      zoneSelect.innerHTML += `<option value="${z.id}">${z.name}</option>`;
    });
  } else {
    const regionZones = state.orgStructure.zones[regionVal] || [];
    regionZones.forEach(zName => {
      zoneSelect.innerHTML += `<option value="${zName}">${zName}</option>`;
    });
  }
}

export function populateAdminGroups() {
  const zoneSelect = document.getElementById("admin-org-zone");
  const groupSelect = document.getElementById("admin-org-group");

  groupSelect.innerHTML = `<option value="">-- é¢ï¿½ï¿½ï¿½è±¢ï¿½ï¿½æ ï¿½è¯ï¿½ --</option>`;

  const zoneVal = zoneSelect.value;
  if (!zoneVal) return;

  if (state.isSupabaseMode && state.orgStructure.rawGroups) {
    const zoneGroups = state.orgStructure.rawGroups.filter(g => g.pastoral_zone_id === zoneVal);
    zoneGroups.forEach(g => {
      groupSelect.innerHTML += `<option value="${g.id}">${g.name}</option>`;
    });
  } else {
    const zoneGroups = state.orgStructure.groups[zoneVal] || [];
    zoneGroups.forEach(gName => {
      groupSelect.innerHTML += `<option value="${gName}">${gName}</option>`;
    });
  }
}

export function showResponsibilityModal(role, user) {
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "modal-overlay";
    overlay.style = `
      position: fixed;
      top: 0; left: 0;
      width: 100vw; height: 100vh;
      background: rgba(15, 23, 42, 0.6);
      backdrop-filter: blur(8px);
      display: flex;
      justify-content: center;
      align-items: center;
      z-index: 99999;
      opacity: 0;
      transition: opacity 0.3s ease;
    `;
    
    const container = document.createElement("div");
    container.className = "glass-card";
    container.style = `
      width: 90%;
      max-width: 460px;
      background: var(--bg-card);
      border: 1px solid var(--border-card);
      border-radius: 16px;
      padding: 1.8rem;
      box-shadow: var(--shadow-lg);
      transform: translateY(20px);
      transition: transform 0.3s ease;
      display: flex;
      flex-direction: column;
      gap: 1rem;
    `;
    
    let roleText = "";
    if (role === "great_zone_leader") roleText = "æ­æ¹ï¿½ï¿½ï¿½ï¿½ï¿½";
    else if (role === "zone_leader") roleText = "ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½";
    else if (role === "group_leader") roleText = "æ ï¿½è¯ï¿½ï¿½ï¿½ï¿½";
    
    let htmlContent = `
      <div style="margin-bottom: 0.2rem;">
        <h3 style="margin-top: 0; margin-bottom: 0.5rem; font-size: 1.2rem; font-weight: 500; color: var(--text-primary);">
          é®åï¿½ï¿½ ${roleText} ï¿½ï¿½ï¿½éï¿½éç¥ï¿½ï¿½ï¿½ï¿½ï¿½
        </h3>
        <p style="font-size: 0.8rem; color: var(--text-muted); margin-bottom: 0; line-height: 1.4;">
          é¢ï¿½ï¿½ï¿½æ¸ï¿½è²åºï¿½ï¿½ï¿½ï¿½ï¿½â¥ï¿½ï¿½èâï¿½ï¿½ï¿½ï¿½ï¿½è­ï¿½ï¿½ï¿½ï¿½åï¿½ï¿½ï¿½èï¿½æ¸²ï¿½ï¿½ï¿½ï¿½è³ï¿½ï¿½ï¿½ï¿½ï¿½èé¤çµæ ï¿½éï¿½çæï¿½ï¿½çï¿½èâ ï¿½ï¿½çï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½
        </p>
      </div>
      
      <div style="display: flex; flex-direction: column; gap: 0.8rem; max-height: 380px; overflow-y: auto; padding-right: 0.2rem;">
    `;
    
    if (role === "great_zone_leader") {
      htmlContent += `
        <div class="form-group" style="margin-bottom: 0;">
          <label style="display: block; font-size: 0.8rem; font-weight: 500; color: var(--text-secondary); margin-bottom: 0.3rem;">éï¿½éç ä¹ï¿½ï¿½ï¿½ (ï¿½ï¿½èªï¿½ï¿½ï¿½ï¿½ï¿½)</label>
          <div id="modal-regions-container" style="background: var(--bg-input); border: 1px solid var(--border-card); border-radius: 6px; padding: 0.6rem; max-height: 220px; overflow-y: auto; display: flex; flex-direction: column; gap: 0.3rem;">
          </div>
        </div>
      `;
    } else if (role === "zone_leader") {
      htmlContent += `
        <div class="form-group" style="margin-bottom: 0;">
          <label style="display: block; font-size: 0.8rem; font-weight: 500; color: var(--text-secondary); margin-bottom: 0.3rem;">éï¿½éç¥ï¿½æ¹ï¿½ï¿½ (ï¿½ï¿½èªï¿½ï¿½ï¿½ï¿½ï¿½)</label>
          <div id="modal-zones-container" style="background: var(--bg-input); border: 1px solid var(--border-card); border-radius: 6px; padding: 0.6rem; max-height: 220px; overflow-y: auto; display: flex; flex-direction: column; gap: 0.3rem;">
          </div>
        </div>
      `;
    } else if (role === "group_leader") {
      htmlContent += `
        <div class="form-group" style="margin-bottom: 0;">
          <label style="display: block; font-size: 0.8rem; font-weight: 500; color: var(--text-secondary); margin-bottom: 0.3rem;">éï¿½éç ï¿½ï¿½è¯ï¿½ (ï¿½ï¿½èªï¿½ï¿½ï¿½ï¿½ï¿½)</label>
          <div id="modal-groups-container" style="background: var(--bg-input); border: 1px solid var(--border-card); border-radius: 6px; padding: 0.6rem; max-height: 220px; overflow-y: auto; display: flex; flex-direction: column; gap: 0.3rem;">
          </div>
        </div>
      `;
    }
    
    htmlContent += `
      </div>
      <div style="display: flex; justify-content: flex-end; gap: 0.6rem; border-top: 1px solid var(--border-card); padding-top: 0.8rem; margin-top: 0.2rem;">
        <button id="modal-btn-cancel" class="pill-btn" style="padding: 0.5rem 1.2rem; font-size: 0.85rem;">ï¿½ï¿½ï¿½ç¨ï¿½</button>
        <button id="modal-btn-confirm" class="primary-btn" style="padding: 0.5rem 1.2rem; font-size: 0.85rem; font-weight: 500;">è£ç®ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½</button>
      </div>
    `;
    
    container.innerHTML = htmlContent;
    overlay.appendChild(container);
    document.body.appendChild(overlay);
    
    setTimeout(() => {
      overlay.style.opacity = "1";
      container.style.transform = "translateY(0)";
    }, 10);
    
    const currentRegions = (user.managed_regions || user.great_region || "").split(",").map(s => s.trim()).filter(Boolean);
    const currentZones = (user.managed_zones || user.pastoral_zone || "").split(",").map(s => s.trim()).filter(Boolean);
    const currentGroups = (user.managed_groups || user.small_group || "").split(",").map(s => s.trim()).filter(Boolean);
    
    const regionContainer = overlay.querySelector("#modal-regions-container");
    const zoneContainer = overlay.querySelector("#modal-zones-container");
    const groupContainer = overlay.querySelector("#modal-groups-container");
    
    if (role === "great_zone_leader" && regionContainer) {
      let regions = [];
      if (state.isSupabaseMode && state.orgStructure.rawRegions) {
        regions = state.orgStructure.rawRegions;
      } else if (state.orgStructure.regions) {
        regions = state.orgStructure.regions.map(rName => ({ id: rName, name: rName }));
      }
      let html = "";
      regions.forEach(r => {
        const isChecked = currentRegions.includes(r.name) ? "checked" : "";
        html += `
          <label style="display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; color: var(--text-primary); cursor: pointer; padding: 0.15rem 0;">
            <input type="checkbox" name="region-checkbox" value="${r.id}" data-name="${r.name}" ${isChecked} style="cursor: pointer;">
            <span>${r.name}</span>
          </label>
        `;
      });
      regionContainer.innerHTML = html || `<span style="font-size: 0.8rem; color: var(--text-muted);">ï¿½ï¿½âªä¹ï¿½ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½</span>`;
    }
    
    if (role === "zone_leader" && zoneContainer) {
      let zones = [];
      if (state.isSupabaseMode && state.orgStructure.rawZones) {
        state.orgStructure.rawZones.forEach(z => {
          const region = state.orgStructure.rawRegions?.find(r => r.id === z.great_region_id);
          const regionSuffix = region ? ` (${region.name})` : "";
          zones.push({ id: z.id, name: z.name, label: `${z.name}${regionSuffix}` });
        });
      } else if (state.orgStructure.zones) {
        for (const [rName, zList] of Object.entries(state.orgStructure.zones)) {
          zList.forEach(zName => {
            zones.push({ id: zName, name: zName, label: `${zName} (${rName})` });
          });
        }
      }
      let html = "";
      zones.forEach(z => {
        const isChecked = currentZones.includes(z.name) ? "checked" : "";
        html += `
          <label style="display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; color: var(--text-primary); cursor: pointer; padding: 0.15rem 0;">
            <input type="checkbox" name="zone-checkbox" value="${z.id}" data-name="${z.name}" ${isChecked} style="cursor: pointer;">
            <span>${z.label}</span>
          </label>
        `;
      });
      zoneContainer.innerHTML = html || `<span style="font-size: 0.8rem; color: var(--text-muted);">ï¿½ï¿½â ï¿½æ¹ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½</span>`;
    }
    
    if (role === "group_leader" && groupContainer) {
      let groups = [];
      if (state.isSupabaseMode && state.orgStructure.rawGroups) {
        state.orgStructure.rawGroups.forEach(g => {
          const zone = state.orgStructure.rawZones?.find(z => z.id === g.pastoral_zone_id);
          const zoneSuffix = zone ? ` (${zone.name})` : "";
          groups.push({ id: g.id, name: g.name, label: `${g.name}${zoneSuffix}` });
        });
      } else if (state.orgStructure.groups) {
        for (const [zName, gList] of Object.entries(state.orgStructure.groups)) {
          gList.forEach(gName => {
            groups.push({ id: gName, name: gName, label: `${gName} (${zName})` });
          });
        }
      }
      let html = "";
      groups.forEach(g => {
        const isChecked = currentGroups.includes(g.name) ? "checked" : "";
        html += `
          <label style="display: flex; align-items: center; gap: 0.5rem; font-size: 0.85rem; color: var(--text-primary); cursor: pointer; padding: 0.15rem 0;">
            <input type="checkbox" name="group-checkbox" value="${g.id}" data-name="${g.name}" ${isChecked} style="cursor: pointer;">
            <span>${g.label}</span>
          </label>
        `;
      });
      groupContainer.innerHTML = html || `<span style="font-size: 0.8rem; color: var(--text-muted);">ï¿½ï¿½âªï¿½ï¿½è¯ï¿½éï¿½ï¿½ï¿½ï¿½</span>`;
    }
    
    const closeModal = (result) => {
      overlay.style.opacity = "0";
      container.style.transform = "translateY(20px)";
      setTimeout(() => {
        overlay.remove();
        resolve(result);
      }, 300);
    };
    
    overlay.querySelector("#modal-btn-cancel").onclick = () => closeModal(null);
    
    overlay.querySelector("#modal-btn-confirm").onclick = () => {
      if (role === "great_zone_leader") {
        const checkedRegions = Array.from(regionContainer.querySelectorAll("input[name='region-checkbox']:checked")).map(cb => cb.dataset.name);
        if (checkedRegions.length === 0) {
          alert("é¢ï¿½ï¿½ï¿½å³ï¿½ï¿½ï¿½ï¿½è±¢ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½æ­æ¹ï¿½ï¿½åï¿½");
          return;
        }
        closeModal({
          managed_regions: checkedRegions.join(","),
          managed_zones: "",
          managed_groups: ""
        });
      } else if (role === "zone_leader") {
        const checkedZones = Array.from(zoneContainer.querySelectorAll("input[name='zone-checkbox']:checked")).map(cb => cb.dataset.name);
        if (checkedZones.length === 0) {
          alert("é¢ï¿½ï¿½ï¿½å³ï¿½ï¿½ï¿½ï¿½è±¢ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½ï¿½ï¿½æ¹ï¿½ï¿½åï¿½");
          return;
        }
        closeModal({
          managed_regions: "",
          managed_zones: checkedZones.join(","),
          managed_groups: ""
        });
      } else if (role === "group_leader") {
        const checkedGroups = Array.from(groupContainer.querySelectorAll("input[name='group-checkbox']:checked")).map(cb => cb.dataset.name);
        if (checkedGroups.length === 0) {
          alert("é¢ï¿½ï¿½ï¿½å³ï¿½ï¿½ï¿½ï¿½è±¢ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½æ ï¿½è¯ï¿½åï¿½");
          return;
        }
        closeModal({
          managed_regions: "",
          managed_zones: "",
          managed_groups: checkedGroups.join(",")
        });
      }
    };
  });
}
function updatePastoralWallControl(enabled, options = {}) {
  const toggle = document.getElementById("admin-pastoral-wall-toggle");
  const status = document.getElementById("admin-pastoral-wall-status");
  if (!toggle || !status) return;
  toggle.setAttribute("aria-checked", enabled ? "true" : "false");
  toggle.setAttribute("aria-label", enabled ? "æ ï¿½æ®ï¿½ï¿½ï¿½æ¹ï¿½ï¿½ï¿½ï¿½ï¿½é½æ¡ï¿½ï¿½é­æï¿½ï¿½" : "ï¿½ï¿½ï¿½ï¿½ï¿½æï¿½æ¹ï¿½ï¿½ï¿½ï¿½ï¿½é½æ¡ï¿½ï¿½é­æï¿½ï¿½");
  toggle.disabled = options.disabled === true;
  status.textContent = enabled ? "ï¿½ï¿½æ¡ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½æ©ï¿½ï¿½æï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½æ¿èå§ï¿½ï¿½ï¿½é­æï¿½ï¿½" : "ï¿½ï¿½æ¡ï¿½ï¿½æ ï¿½æ®ï¿½åï¿½æï¿½ï¿½ï¿½ï¿½éï¿½æ¿èå§ï¿½ï¿½ï¿½é­æï¿½ï¿½";
}

export async function renderAdminFeatureSettings() {
  const card = document.querySelector(".admin-feature-settings-card")?.closest(".card-col");
  const toggle = document.getElementById("admin-pastoral-wall-toggle");
  const feedback = document.getElementById("admin-pastoral-wall-feedback");
  if (!card || !toggle || !feedback) return;

  const isAdmin = state.currentUser && state.currentUser.role === "admin";
  card.classList.toggle("hidden", !isAdmin);
  if (!isAdmin) return;

  feedback.classList.add("hidden");
  feedback.textContent = "";
  updatePastoralWallControl(false, { disabled: true });

  const result = await db.getFeatureSetting("pastoral_sharing_wall", false);
  if (result.error) {
    updatePastoralWallControl(false, { disabled: true });
    feedback.textContent = "ï¿½ï¿½æ¡ï¿½ï¿½ï¿½ï¿½â¥ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½é®åï¿½ï¿½åï¿½é¢ï¿½è£ç®ï¿½ï¿½éï¿½ï¿½ï¿½ï¿½æ¨æ¥ï¿½æ¹ï¿½å£æ­æ°ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½";
    feedback.classList.remove("hidden");
    return;
  }

  updatePastoralWallControl(result.enabled === true);

  if (!toggle.dataset.featureSettingBound) {
    toggle.dataset.featureSettingBound = "true";
    toggle.addEventListener("click", async () => {
      const currentEnabled = toggle.getAttribute("aria-checked") === "true";
      const nextEnabled = !currentEnabled;
      updatePastoralWallControl(currentEnabled, { disabled: true });
      feedback.classList.add("hidden");

      const saveResult = await db.updateFeatureSetting("pastoral_sharing_wall", nextEnabled);
      if (saveResult.error) {
        updatePastoralWallControl(currentEnabled);
        feedback.textContent = "é®åï¿½ï¿½çï¿½ï¿½ï¿½ï¿½ï¿½ï¿½è£ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½åï¿½é¢ï¿½èï¿½æºï¿½ï¿½ï¿½ï¿½é°è¾ï¿½ï¿½";
        feedback.classList.remove("hidden");
        return;
      }

      updatePastoralWallControl(nextEnabled);
      if (typeof showToast === "function") {
        showToast(nextEnabled ? "ï¿½ï¿½æ¹ï¿½ï¿½ï¿½ï¿½ï¿½é½æ¡ï¿½ï¿½é­æï¿½ï¿½æè¤ï¿½ï¿½ï¿½ï¿½ï¿½" : "ï¿½ï¿½æ¹ï¿½ï¿½ï¿½ï¿½ï¿½é½æ¡ï¿½ï¿½é­æï¿½ï¿½æè£ï¿½ï¿½æ®ï¿½");
      }
      window.dispatchEvent(new CustomEvent("pastoral-sharing-wall-changed", {
        detail: { enabled: nextEnabled }
      }));
    });
  }

  if (typeof hydrateIcons === "function") hydrateIcons(card);
}


export function init() {
  const searchInput = document.getElementById("admin-search-user");
  if (searchInput) {
    let debounceTimer;
    searchInput.oninput = () => {
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        renderAdminUserManagement();
      }, 300);
    };
  }

  initAdminOrgManagement();
  initAdminFiltersUI();
}

// Bind to window for global access compatibility
window.renderAdminUserManagement = renderAdminUserManagement;
window.renderAdminOrgManagement = renderAdminOrgManagement;
window.initAdminFiltersUI = initAdminFiltersUI;
window.renderAdminFeatureSettings = renderAdminFeatureSettings;
window.openAdminFilterBottomSheet = openAdminFilterBottomSheet;
window.closeAdminFilterBottomSheet = closeAdminFilterBottomSheet;
window.initAdminUserManagement = init;

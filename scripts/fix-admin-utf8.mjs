import fs from 'fs';
import path from 'path';

const filepath = path.resolve('js/modules/admin.js');
console.log('Reading file:', filepath);

// Read as binary/latin1 to preserve exact bytes
const content = fs.readFileSync(filepath, 'binary');

const startAnchor = '  document.getElementById("admin-add-region-btn").onclick = async () => {';
const endAnchor = 'export function renderAdminOrgManagement()';

const startIndex = content.indexOf(startAnchor);
const endIndex = content.indexOf(endAnchor);

if (startIndex === -1) {
  console.error('Could not find start anchor in admin.js');
  process.exit(1);
}

if (endIndex === -1) {
  console.error('Could not find end anchor in admin.js');
  process.exit(1);
}

console.log(`Found start anchor at index ${startIndex}, end anchor at index ${endIndex}`);

const replacementText = `  document.getElementById("admin-add-region-btn").onclick = async () => {
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
    const newName = prompt(\`修改大區 \${oldName} 名稱\`, oldName);
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
      message: \`確定要刪除大區「\${opt.text}」嗎？此操作將同時刪除該大區下屬的所有牧區與小組！\`,
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
    const newName = prompt(\`修改牧區 \${oldName} 名稱\`, oldName);
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
      message: \`確定要刪除牧區「\${opt.text}」嗎？此操作將同時刪除該牧區下屬的所有小組！\`,
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
    const newName = prompt(\`修改小組 \${oldName} 名稱\`, oldName);
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
      message: \`確定要刪除小組「\${opt.text}」嗎？此操作將刪除該小組的所有讀經狀態！\`,
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

`;

// Reconstruct the file contents
// Keep the text before the start of the block, insert the clean UTF-8 replacementText,
// and append the text after the end of the block.
const newContent = content.substring(0, startIndex) + replacementText + content.substring(endIndex);

// Save back as UTF-8
fs.writeFileSync(filepath, newContent, 'utf-8');
console.log('Successfully updated admin.js with clean UTF-8 strings!');

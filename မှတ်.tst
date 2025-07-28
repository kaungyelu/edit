// worker.js
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request))
})

// Global variables to store data (in-memory, will reset on worker restart)
let adminId = null;
let userData = {};       // {username: {date_key: [{num: number, amt: number}]}}
let ledger = {};         // {date_key: {number: total_amount}}
let breakLimits = {};    // {date_key: limit}
let pnumberPerDate = {}; // {date_key: power_number}
let dateControl = {};    // {date_key: true/false}
let overbuyList = {};    // {date_key: {username: {num: amount}}}
let messageStore = {};    // {user_id_message_id: {sentMessageId: number, bets: string[], totalAmount: number, dateKey: string}}
let overbuySelections = {}; // {date_key: {username: {num: amount}}}
let currentWorkingDate = null; // For admin date selection
let comData = {};        // {username: com_percentage}
let zaData = {};         // {username: za_multiplier}

// Timezone setup (Myanmar time)
const MYANMAR_TIMEZONE = 'Asia/Yangon';

// Helper functions
function reverseNumber(n) {
  const s = n.toString().padStart(2, '0');
  return parseInt(s.split('').reverse().join(''));
}

function getTimeSegment() {
  const now = new Date(new Date().toLocaleString('en-US', { timeZone: MYANMAR_TIMEZONE }));
  return now.getHours() < 12 ? 'AM' : 'PM';
}

function getCurrentDateKey() {
  const now = new Date(new Date().toLocaleString('en-US', { timeZone: MYANMAR_TIMEZONE }));
  const day = now.getDate().toString().padStart(2, '0');
  const month = (now.getMonth() + 1).toString().padStart(2, '0');
  const year = now.getFullYear();
  return `${day}/${month}/${year} ${getTimeSegment()}`;
}

function getAvailableDates() {
  const dates = new Set();
  
  // Get dates from user data
  for (const userDataDict of Object.values(userData)) {
    for (const date of Object.keys(userDataDict)) {
      dates.add(date);
    }
  }
  
  // Get dates from ledger
  for (const date of Object.keys(ledger)) {
    dates.add(date);
  }
  
  // Get dates from break limits
  for (const date of Object.keys(breakLimits)) {
    dates.add(date);
  }
  
  // Get dates from pnumber
  for (const date of Object.keys(pnumberPerDate)) {
    dates.add(date);
  }
  
  return Array.from(dates).sort((a, b) => new Date(b.split(' ')[0].split('/').reverse().join('-')) - new Date(a.split(' ')[0].split('/').reverse().join('-')));
}

// Telegram Bot API interaction
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

async function sendMessage(chatId, text, replyMarkup = null) {
  const payload = {
    chat_id: chatId,
    text: text,
    parse_mode: 'HTML'
  };
  
  if (replyMarkup) {
    payload.reply_markup = replyMarkup;
  }
  
  return fetch(`${TELEGRAM_API}/sendMessage`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(payload)
  });
}

async function editMessageText(chatId, messageId, text, replyMarkup = null) {
  const payload = {
    chat_id: chatId,
    message_id: messageId,
    text: text,
    parse_mode: 'HTML'
  };
  
  if (replyMarkup) {
    payload.reply_markup = replyMarkup;
  }
  
  return fetch(`${TELEGRAM_API}/editMessageText`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(payload)
  });
}

async function answerCallbackQuery(callbackQueryId, text = '', showAlert = false) {
  return fetch(`${TELEGRAM_API}/answerCallbackQuery`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      callback_query_id: callbackQueryId,
      text: text,
      show_alert: showAlert
    })
  });
}

// Command handlers
async function handleStart(chatId, userId, username) {
  adminId = userId;
  currentWorkingDate = getCurrentDateKey();
  await sendMessage(chatId, "🤖 Bot started. Admin privileges granted!");
  await showMenu(chatId, userId);
}

async function showMenu(chatId, userId) {
  let keyboard = [];
  
  if (userId === adminId) {
    keyboard = [
      ["အရောင်းဖွင့်ရန်", "အရောင်းပိတ်ရန်"],
      ["လည်ချာ", "ဘရိတ်သတ်မှတ်ရန်"],
      ["လျှံဂဏန်းများဝယ်ရန်", "ပေါက်သီးထည့်ရန်"],
      ["ကော်နှင့်အဆ သတ်မှတ်ရန်", "လက်ရှိအချိန်မှစုစုပေါင်း"],
      ["ဂဏန်းနှင့်ငွေပေါင်း", "ကော်မရှင်များ"],
      ["ရက်ချိန်းရန်", "တစ်ယောက်ခြင်းစာရင်း"],
      ["ရက်အလိုက်စာရင်းစုစုပေါင်း"],
      ["ရက်အကုန်ဖျက်ရန်", "ရက်အလိုက်ဖျက်ရန်"]
    ];
  } else {
    keyboard = [
      ["တစ်ယောက်ခြင်းစာရင်း"]
    ];
  }
  
  const replyMarkup = {
    keyboard: keyboard,
    resize_keyboard: true
  };
  
  await sendMessage(chatId, "မီနူးကိုရွေးချယ်ပါ", { reply_markup: replyMarkup });
}

async function handleMenuSelection(chatId, userId, text) {
  const commandMap = {
    "အရောင်းဖွင့်ရန်": "dateopen",
    "အရောင်းပိတ်ရန်": "dateclose",
    "လည်ချာ": "ledger",
    "ဘရိတ်သတ်မှတ်ရန်": "break",
    "လျှံဂဏန်းများဝယ်ရန်": "overbuy",
    "ပေါက်သီးထည့်ရန်": "pnumber",
    "ကော်နှင့်အဆ သတ်မှတ်ရန်": "comandza",
    "လက်ရှိအချိန်မှစုစုပေါင်း": "total",
    "ဂဏန်းနှင့်ငွေပေါင်း": "tsent",
    "ကော်မရှင်များ": "alldata",
    "ရက်အကုန်ဖျက်ရန်": "reset",
    "တစ်ယောက်ခြင်းစာရင်း": "posthis",
    "ရက်အလိုက်စာရင်းစုစုပေါင်း": "dateall",
    "ရက်ချိန်းရန်": "Cdate",
    "ရက်အလိုက်ဖျက်ရန်": "Ddate"
  };
  
  if (commandMap[text]) {
    const command = commandMap[text];
    switch (command) {
      case "dateopen":
        await dateOpen(chatId, userId);
        break;
      case "dateclose":
        await dateClose(chatId, userId);
        break;
      case "ledger":
        await ledgerSummary(chatId, userId);
        break;
      case "break":
        await breakCommand(chatId, userId, '');
        break;
      case "overbuy":
        await overbuy(chatId, userId, '');
        break;
      case "pnumber":
        await pnumber(chatId, userId, '');
        break;
      case "comandza":
        await comandza(chatId, userId);
        break;
      case "total":
        await total(chatId, userId);
        break;
      case "tsent":
        await tsent(chatId, userId);
        break;
      case "alldata":
        await alldata(chatId, userId);
        break;
      case "reset":
        await resetData(chatId, userId);
        break;
      case "posthis":
        await posthis(chatId, userId, '');
        break;
      case "dateall":
        await dateall(chatId, userId);
        break;
      case "Cdate":
        await changeWorkingDate(chatId, userId);
        break;
      case "Ddate":
        await deleteDate(chatId, userId);
        break;
    }
  }
}

async function dateOpen(chatId, userId) {
  if (userId !== adminId) {
    await sendMessage(chatId, "❌ Admin only command");
    return;
  }
  
  const key = getCurrentDateKey();
  dateControl[key] = true;
  await sendMessage(chatId, `✅ ${key} စာရင်းဖွင့်ပြီးပါပြီ`);
}

async function dateClose(chatId, userId) {
  if (userId !== adminId) {
    await sendMessage(chatId, "❌ Admin only command");
    return;
  }
  
  const key = getCurrentDateKey();
  dateControl[key] = false;
  await sendMessage(chatId, `✅ ${key} စာရင်းပိတ်လိုက်ပါပြီ`);
}

async function handleMessage(chatId, userId, username, messageId, text) {
  try {
    if (!username) {
      await sendMessage(chatId, "❌ ကျေးဇူးပြု၍ Telegram username သတ်မှတ်ပါ");
      return;
    }

    const key = getCurrentDateKey();
    if (!dateControl[key]) {
      await sendMessage(chatId, "❌ စာရင်းပိတ်ထားပါသည်");
      return;
    }

    if (!text) {
      await sendMessage(chatId, "⚠️ မက်ဆေ့ဂျ်မရှိပါ");
      return;
    }

    // Process the message line by line
    const lines = text.split('\n');
    const allBets = [];
    let totalAmount = 0;

    for (const line of lines) {
      const trimmedLine = line.trim();
      if (!trimmedLine) continue;

      // Check for wheel cases first
      if (trimmedLine.includes('အခွေ') || trimmedLine.includes('အပူးပါအခွေ')) {
        let basePart, amountPart;
        if (trimmedLine.includes('အခွေ')) {
          const parts = trimmedLine.split('အခွေ');
          basePart = parts[0];
          amountPart = parts[1];
        } else {
          const parts = trimmedLine.split('အပူးပါအခွေ');
          basePart = parts[0];
          amountPart = parts[1];
        }
        
        // Clean base numbers (remove all non-digits)
        const baseNumbers = basePart.replace(/\D/g, '');
        
        // Clean amount (remove all non-digits)
        const amount = parseInt(amountPart.replace(/\D/g, ''));
        
        // Generate all possible pairs
        const pairs = [];
        for (let i = 0; i < baseNumbers.length; i++) {
          for (let j = 0; j < baseNumbers.length; j++) {
            if (i !== j) {
              const num = parseInt(baseNumbers[i] + baseNumbers[j]);
              if (!pairs.includes(num)) {
                pairs.push(num);
              }
            }
          }
        }
        
        // If အပူးပါအခွေ, add doubles
        if (trimmedLine.includes('အပူးပါအခွေ')) {
          for (const d of baseNumbers) {
            const double = parseInt(d + d);
            if (!pairs.includes(double)) {
              pairs.push(double);
            }
          }
        }
        
        // Add all bets
        for (const num of pairs) {
          allBets.push(`${num.toString().padStart(2, '0')}-${amount}`);
          totalAmount += amount;
        }
        continue;
      }

      // Check for special cases
      const specialCases = {
        "အပူး": [0, 11, 22, 33, 44, 55, 66, 77, 88, 99],
        "ပါဝါ": [5, 16, 27, 38, 49, 50, 61, 72, 83, 94],
        "နက္ခ": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နခ": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နက်ခ": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နတ်ခ": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နခက်": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နတ်ခက်": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နက်ခက်": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နတ်ခတ်": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နက်ခတ်": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နခတ်": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "နခပ်": [7, 18, 24, 35, 42, 53, 69, 70, 81, 96],
        "ညီကို": [1, 12, 23, 34, 45, 56, 67, 78, 89, 90],
        "ကိုညီ": [9, 10, 21, 32, 43, 54, 65, 76, 87, 98],
      };

      const dynamicTypes = ["ထိပ်", "ပိတ်", "ဘရိတ်", "အပါ"];
      
      // Check for special cases with flexible formatting
      let foundSpecial = false;
      for (const [caseName, caseNumbers] of Object.entries(specialCases)) {
        const caseVariations = [caseName];
        if (caseName === "နက္ခ") {
          caseVariations.push("နခ", "နက်ခ", "နတ်ခ", "နခက်", "နတ်ခက်", "နက်ခက်", "နတ်ခတ်", "နက်ခတ်", "နခတ်", "နခပ်");
        }
        
        for (const variation of caseVariations) {
          if (trimmedLine.startsWith(variation)) {
            // Extract amount - allow any separator or none
            let amountStr = trimmedLine.slice(variation.length).trim();
            // Remove all non-digit characters
            amountStr = amountStr.replace(/\D/g, '');
            
            if (amountStr && parseInt(amountStr) >= 100) {
              const amt = parseInt(amountStr);
              for (const num of caseNumbers) {
                allBets.push(`${num.toString().padStart(2, '0')}-${amt}`);
                totalAmount += amt;
              }
              foundSpecial = true;
              break;
            }
          }
          if (foundSpecial) break;
        }
        if (foundSpecial) break;
      }
      
      if (foundSpecial) continue;

      // Check for dynamic types with flexible formatting
      for (const dtype of dynamicTypes) {
        if (trimmedLine.includes(dtype)) {
          // Extract all numbers from the line
          let numbers = [];
          let amount = 0;
          
          // Find all number parts
          const parts = trimmedLine.match(/\d+/g);
          if (parts && parts.length > 0) {
            // The last number is the amount
            amount = parseInt(parts[parts.length - 1]) >= 100 ? parseInt(parts[parts.length - 1]) : 0;
            // Other numbers are the digits
            const digits = parts.slice(0, -1).filter(p => p.length === 1 && /\d/.test(p)).map(p => parseInt(p));
          
            if (amount >= 100 && digits.length > 0) {
              numbers = [];
              if (dtype === "ထိပ်") {
                for (const d of digits) {
                  numbers.push(...Array.from({ length: 10 }, (_, j) => d * 10 + j));
                }
              } else if (dtype === "ပိတ်") {
                for (const d of digits) {
                  numbers.push(...Array.from({ length: 10 }, (_, j) => j * 10 + d));
                }
              } else if (dtype === "ဘရိတ်") {
                for (const d of digits) {
                  numbers.push(...Array.from({ length: 100 }, (_, n) => n).filter(n => (Math.floor(n / 10) + n % 10) % 10 === d));
                }
              } else if (dtype === "အပါ") {
                for (const d of digits) {
                  const tens = Array.from({ length: 10 }, (_, j) => d * 10 + j);
                  const units = Array.from({ length: 10 }, (_, j) => j * 10 + d);
                  numbers.push(...new Set([...tens, ...units]));
                }
              }
              
              for (const num of numbers) {
                allBets.push(`${num.toString().padStart(2, '0')}-${amount}`);
                totalAmount += amount;
              }
              foundSpecial = true;
              break;
            }
          }
        }
      }
      
      if (foundSpecial) continue;

      // Process regular number-amount pairs with r/R (flexible formatting)
      if (/r/i.test(trimmedLine)) {
        // Split into parts before and after r/R
        const rPos = trimmedLine.toLowerCase().indexOf('r');
        const beforeR = trimmedLine.slice(0, rPos);
        const afterR = trimmedLine.slice(rPos + 1);
        
        // Extract numbers before r
        const numsBefore = (beforeR.match(/\d+/g) || []).filter(n => parseInt(n) >= 0 && parseInt(n) <= 99).map(n => parseInt(n));
        
        // Extract amounts after r
        const amounts = (afterR.match(/\d+/g) || []).filter(a => parseInt(a) >= 100).map(a => parseInt(a));
        
        if (numsBefore.length > 0 && amounts.length > 0) {
          if (amounts.length === 1) {
            // Single amount: apply to both base and reverse
            for (const num of numsBefore) {
              allBets.push(`${num.toString().padStart(2, '0')}-${amounts[0]}`);
              allBets.push(`${reverseNumber(num).toString().padStart(2, '0')}-${amounts[0]}`);
              totalAmount += amounts[0] * 2;
            }
          } else {
            // Two amounts: first for base, second for reverse
            for (const num of numsBefore) {
              allBets.push(`${num.toString().padStart(2, '0')}-${amounts[0]}`);
              allBets.push(`${reverseNumber(num).toString().padStart(2, '0')}-${amounts[1]}`);
              totalAmount += amounts[0] + amounts[1];
            }
          }
          continue;
        }
      }

      // Process regular number-amount pairs without r/R (flexible formatting)
      let numbers = [];
      let amount = 0;
      
      // Find all numbers in the line
      const allNumbers = trimmedLine.match(/\d+/g) || [];
      if (allNumbers.length > 0) {
        // The last number is the amount if it's >= 100
        if (parseInt(allNumbers[allNumbers.length - 1]) >= 100) {
          amount = parseInt(allNumbers[allNumbers.length - 1]);
          // Other numbers are the bet numbers
          numbers = allNumbers.slice(0, -1).filter(n => parseInt(n) >= 0 && parseInt(n) <= 99).map(n => parseInt(n));
        } else {
          // Maybe the line is just numbers separated by something
          // Try to find pairs where second number is >= 100
          for (let i = 0; i < allNumbers.length - 1; i++) {
            if (parseInt(allNumbers[i]) >= 0 && parseInt(allNumbers[i]) <= 99 && parseInt(allNumbers[i + 1]) >= 100) {
              numbers.push(parseInt(allNumbers[i]));
              amount = parseInt(allNumbers[i + 1]);
              break;
            }
          }
        }
      }
      
      if (amount >= 100 && numbers.length > 0) {
        for (const num of numbers) {
          allBets.push(`${num.toString().padStart(2, '0')}-${amount}`);
          totalAmount += amount;
        }
      }
    }

    if (allBets.length === 0) {
      await sendMessage(chatId, "⚠️ အချက်အလက်များကိုစစ်ဆေးပါ\nဥပမာ: 12-1000,12/34-1000 \n 12r1000,12r1000-500");
      return;
    }

    // Update data stores
    if (!userData[username]) {
      userData[username] = {};
    }
    if (!userData[username][key]) {
      userData[username][key] = [];
    }

    if (!ledger[key]) {
      ledger[key] = {};
    }

    for (const bet of allBets) {
      const [numStr, amtStr] = bet.split('-');
      const num = parseInt(numStr);
      const amt = parseInt(amtStr);
      
      // Update ledger
      if (!ledger[key][num]) {
        ledger[key][num] = 0;
      }
      ledger[key][num] += amt;
      
      // Update user data
      userData[username][key].push({ num, amt });
    }

    // Send confirmation with delete button
    const response = allBets.join('\n') + `\nစုစုပေါင်း ${totalAmount} ကျပ်`;
    const keyboard = [[{
      text: "🗑 Delete",
      callback_data: `delete:${userId}:${messageId}:${key}`
    }]];
    
    const sentMessage = await sendMessage(chatId, response, {
      reply_markup: { inline_keyboard: keyboard }
    });
    
    const sentMessageData = await sentMessage.json();
    messageStore[`${userId}_${messageId}`] = {
      sentMessageId: sentMessageData.result.message_id,
      bets: allBets,
      totalAmount,
      dateKey: key
    };
  } catch (e) {
    console.error(`Error in handleMessage: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function deleteBet(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, userIdStr, messageIdStr, dateKey] = callbackData.split(':');
    const messageId = parseInt(messageIdStr);
    
    // Only admin can interact with delete button
    if (userId !== adminId) {
      await editMessageText(chatId, messageId, "❌ Admin only action");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    const keyboard = [
      [{
        text: "✅ OK",
        callback_data: `confirm_delete:${userIdStr}:${messageIdStr}:${dateKey}`
      }],
      [{
        text: "❌ Cancel",
        callback_data: `cancel_delete:${userIdStr}:${messageIdStr}:${dateKey}`
      }]
    ];
    
    await editMessageText(chatId, messageId, "⚠️ သေချာလား? ဒီလောင်းကြေးကိုဖျက်မှာလား?", {
      reply_markup: { inline_keyboard: keyboard }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in deleteBet: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred while processing deletion");
  }
}

async function confirmDelete(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, userIdStr, messageIdStr, dateKey] = callbackData.split(':');
    const userIdNum = parseInt(userIdStr);
    const messageId = parseInt(messageIdStr);
    
    const messageKey = `${userIdNum}_${messageId}`;
    if (!messageStore[messageKey]) {
      await editMessageText(chatId, messageId, "❌ ဒေတာမတွေ့ပါ");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    const { sentMessageId, bets, totalAmount,  } = messageStore[messageKey];
    
    let foundUsername = null;
    for (const [uname, data] of Object.entries(userData)) {
      if (data[dateKey]) {
        for (const bet of data[dateKey]) {
          const betStr = `${bet.num.toString().padStart(2, '0')}-${bet.amt}`;
          if (bets.includes(betStr)) {
            foundUsername = uname;
            break;
          }
        }
        if (foundUsername) break;
      }
    }
    
    if (!foundUsername) {
      await editMessageText(chatId, messageId, "❌ User မတွေ့ပါ");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    for (const bet of bets) {
      const [numStr, amtStr] = bet.split('-');
      const num = parseInt(numStr);
      const amt = parseInt(amtStr);
      
      if (ledger[dateKey] && ledger[dateKey][num]) {
        ledger[dateKey][num] -= amt;
        if (ledger[dateKey][num] <= 0) {
          delete ledger[dateKey][num];
        }
        // Remove date from ledger if empty
        if (Object.keys(ledger[dateKey]).length === 0) {
          delete ledger[dateKey];
        }
      }
      
      if (userData[foundUsername] && userData[foundUsername][dateKey]) {
        userData[foundUsername][dateKey] = userData[foundUsername][dateKey].filter(
          b => !(b.num === num && b.amt === amt)
        );
        
        if (userData[foundUsername][dateKey].length === 0) {
          delete userData[foundUsername][dateKey];
          if (Object.keys(userData[foundUsername]).length === 0) {
            delete userData[foundUsername];
          }
        }
      }
    }
    
    delete messageStore[messageKey];
    
    await editMessageText(chatId, messageId, "✅ လောင်းကြေးဖျက်ပြီးပါပြီ");
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in confirmDelete: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred while deleting bet");
  }
}

async function cancelDelete(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, userIdStr, messageIdStr, dateKey] = callbackData.split(':');
    const userIdNum = parseInt(userIdStr);
    const messageId = parseInt(messageIdStr);
    
    const messageKey = `${userIdNum}_${messageId}`;
    if (messageStore[messageKey]) {
      const { sentMessageId, bets, totalAmount, _ } = messageStore[messageKey];
      const response = bets.join('\n') + `\nစုစုပေါင်း ${totalAmount} ကျပ်`;
      const keyboard = [[{
        text: "🗑 Delete",
        callback_data: `delete:${userIdStr}:${messageIdStr}:${dateKey}`
      }]];
      
      await editMessageText(chatId, messageId, response, {
        reply_markup: { inline_keyboard: keyboard }
      });
    } else {
      await editMessageText(chatId, messageId, "ℹ️ ဖျက်ခြင်းကိုပယ်ဖျက်လိုက်ပါပြီ");
    }
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in cancelDelete: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred while canceling deletion");
  }
}

async function ledgerSummary(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Determine which date to show
    const dateKey = currentWorkingDate || getCurrentDateKey();
    
    if (!ledger[dateKey]) {
      await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် လက်ရှိတွင် လောင်းကြေးမရှိပါ`);
      return;
    }
    
    let lines = [`📒 ${dateKey} လက်ကျန်ငွေစာရင်း`];
    const ledgerData = ledger[dateKey];
    
    let totalAllNumbers = 0;  // စုစုပေါင်းငွေအတွက်
    
    for (let i = 0; i < 100; i++) {
      const total = ledgerData[i] || 0;
      if (total > 0) {
        if (pnumberPerDate[dateKey] === i) {
          lines.push(`🔴 ${i.toString().padStart(2, '0')} ➤ ${total} 🔴`);
        } else {
          lines.push(`${i.toString().padStart(2, '0')} ➤ ${total}`);
        }
        totalAllNumbers += total;
      }
    }

    if (lines.length === 1) {
      await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် လက်ရှိတွင် လောင်းကြေးမရှိပါ`);
    } else {
      if (pnumberPerDate[dateKey] !== undefined) {
        const pnum = pnumberPerDate[dateKey];
        lines.push(`\n🔴 Power Number: ${pnum.toString().padStart(2, '0')} ➤ ${ledgerData[pnum] || 0}`);
      }
      
      // စုစုပေါင်းငွေပြရန် အောက်ခြေတွင် ထည့်ပါ
      lines.push(`\n💰 စုစုပေါင်း: ${totalAllNumbers} ကျပ်`);
      await sendMessage(chatId, lines.join('\n'));
    }
  } catch (e) {
    console.error(`Error in ledger: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function breakCommand(chatId, userId, args) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Determine which date to work on
    const dateKey = currentWorkingDate || getCurrentDateKey();
        
    if (!args) {
      if (breakLimits[dateKey] !== undefined) {
        await sendMessage(chatId, `ℹ️ Usage: /break [limit]\nℹ️ လက်ရှိတွင် break limit: ${breakLimits[dateKey]}`);
      } else {
        await sendMessage(chatId, `ℹ️ Usage: /break [limit]\nℹ️ ${dateKey} အတွက် break limit မသတ်မှတ်ရသေးပါ`);
      }
      return;
    }
    
    try {
      const newLimit = parseInt(args);
      breakLimits[dateKey] = newLimit;
      await sendMessage(chatId, `✅ ${dateKey} အတွက် Break limit ကို ${newLimit} အဖြစ်သတ်မှတ်ပြီးပါပြီ`);
      
      if (!ledger[dateKey]) {
        await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် လောင်းကြေးမရှိသေးပါ`);
        return;
      }
      
      const ledgerData = ledger[dateKey];
      const msg = [`📌 ${dateKey} အတွက် Limit (${newLimit}) ကျော်ဂဏန်းများ:`];
      let found = false;
      
      for (const [num, amt] of Object.entries(ledgerData)) {
        if (amt > newLimit) {
          msg.push(`${num.toString().padStart(2, '0')} ➤ ${amt - newLimit}`);
          found = true;
        }
      }
      
      if (!found) {
        await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် ဘယ်ဂဏန်းမှ limit (${newLimit}) မကျော်ပါ`);
      } else {
        await sendMessage(chatId, msg.join('\n'));
      }
    } catch {
      await sendMessage(chatId, "⚠️ Limit amount ထည့်ပါ (ဥပမာ: /break 5000)");
    }
  } catch (e) {
    console.error(`Error in break: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function overbuy(chatId, userId, args) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Determine which date to work on
    const dateKey = currentWorkingDate || getCurrentDateKey();
        
    if (!args) {
      await sendMessage(chatId, "ℹ️ ကာဒိုင်အမည်ထည့်ပါ");
      return;
    }
    
    if (breakLimits[dateKey] === undefined) {
      await sendMessage(chatId, `⚠️ ${dateKey} အတွက် ကျေးဇူးပြု၍ /break [limit] ဖြင့် limit သတ်မှတ်ပါ`);
      return;
    }
    
    if (!ledger[dateKey]) {
      await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် လောင်းကြေးမရှိသေးပါ`);
      return;
    }
    
    const username = args;
    const context = { user_data: { overbuy_username: username, overbuy_date: dateKey } };
    
    const ledgerData = ledger[dateKey];
    const breakLimitVal = breakLimits[dateKey];
    const overNumbers = {};
    
    for (const [num, amt] of Object.entries(ledgerData)) {
      if (amt > breakLimitVal) {
        overNumbers[num] = amt - breakLimitVal;
      }
    }
    
    if (Object.keys(overNumbers).length === 0) {
      await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် ဘယ်ဂဏန်းမှ limit (${breakLimitVal}) မကျော်ပါ`);
      return;
    }
    
    if (!overbuySelections[dateKey]) {
      overbuySelections[dateKey] = {};
    }
    overbuySelections[dateKey][username] = { ...overNumbers };
    
    const msg = [`${username} ထံမှာတင်ရန်များ (Date: ${dateKey}, Limit: ${breakLimitVal}):`];
    const buttons = [];
    
    for (const [num, amt] of Object.entries(overNumbers)) {
      const isSelected = overbuySelections[dateKey][username][num] !== undefined;
      buttons.push([{
        text: `${num.toString().padStart(2, '0')} ➤ ${amt} ${isSelected ? '✅' : '⬜'}`,
        callback_data: `overbuy_select:${num}`
      }]);
    }
    
    buttons.push([
      { text: "Select All", callback_data: "overbuy_select_all" },
      { text: "Unselect All", callback_data: "overbuy_unselect_all" }
    ]);
    buttons.push([{ text: "OK", callback_data: "overbuy_confirm" }]);
    
    await sendMessage(chatId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
  } catch (e) {
    console.error(`Error in overbuy: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function overbuySelect(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, numStr] = callbackData.split(':');
    const num = parseInt(numStr);
    const context = { user_data: { overbuy_username: null, overbuy_date: null } };
    
    const username = context.user_data.overbuy_username;
    const dateKey = context.user_data.overbuy_date;
    
    if (!username || !dateKey) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: User or date not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    if (!overbuySelections[dateKey] || !overbuySelections[dateKey][username]) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: Selection data not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    if (overbuySelections[dateKey][username][num] !== undefined) {
      delete overbuySelections[dateKey][username][num];
    } else {
      const breakLimitVal = breakLimits[dateKey];
      overbuySelections[dateKey][username][num] = ledger[dateKey][num] - breakLimitVal;
    }
    
    const msg = [`${username} ထံမှာတင်ရန်များ (Date: ${dateKey}):`];
    const buttons = [];
    
    for (const [n, amt] of Object.entries(overbuySelections[dateKey][username])) {
      const isSelected = overbuySelections[dateKey][username][n] !== undefined;
      buttons.push([{
        text: `${n.toString().padStart(2, '0')} ➤ ${amt} ${isSelected ? '✅' : '⬜'}`,
        callback_data: `overbuy_select:${n}`
      }]);
    }
    
    buttons.push([
      { text: "Select All", callback_data: "overbuy_select_all" },
      { text: "Unselect All", callback_data: "overbuy_unselect_all" }
    ]);
    buttons.push([{ text: "OK", callback_data: "overbuy_confirm" }]);
    
    await editMessageText(chatId, callbackQueryId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in overbuy_select: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function overbuySelectAll(chatId, userId, callbackQueryId) {
  try {
    const context = { user_data: { overbuy_username: null, overbuy_date: null } };
    const username = context.user_data.overbuy_username;
    const dateKey = context.user_data.overbuy_date;
    
    if (!username || !dateKey) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: User or date not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    if (!overbuySelections[dateKey]) {
      overbuySelections[dateKey] = {};
    }
    
    const breakLimitVal = breakLimits[dateKey];
    const ledgerData = ledger[dateKey];
    overbuySelections[dateKey][username] = {};
    
    for (const [num, amt] of Object.entries(ledgerData)) {
      if (amt > breakLimitVal) {
        overbuySelections[dateKey][username][num] = amt - breakLimitVal;
      }
    }
    
    const msg = [`${username} ထံမှာတင်ရန်များ (Date: ${dateKey}):`];
    const buttons = [];
    
    for (const [num, amt] of Object.entries(overbuySelections[dateKey][username])) {
      buttons.push([{
        text: `${num.toString().padStart(2, '0')} ➤ ${amt} ✅`,
        callback_data: `overbuy_select:${num}`
      }]);
    }
    
    buttons.push([
      { text: "Select All", callback_data: "overbuy_select_all" },
      { text: "Unselect All", callback_data: "overbuy_unselect_all" }
    ]);
    buttons.push([{ text: "OK", callback_data: "overbuy_confirm" }]);
    
    await editMessageText(chatId, callbackQueryId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in overbuy_select_all: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function overbuyUnselectAll(chatId, userId, callbackQueryId) {
  try {
    const context = { user_data: { overbuy_username: null, overbuy_date: null } };
    const username = context.user_data.overbuy_username;
    const dateKey = context.user_data.overbuy_date;
    
    if (!username || !dateKey) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: User or date not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    if (!overbuySelections[dateKey]) {
      overbuySelections[dateKey] = {};
    }
    
    overbuySelections[dateKey][username] = {};
    
    const breakLimitVal = breakLimits[dateKey];
    const ledgerData = ledger[dateKey];
    const overNumbers = {};
    
    for (const [num, amt] of Object.entries(ledgerData)) {
      if (amt > breakLimitVal) {
        overNumbers[num] = amt - breakLimitVal;
      }
    }
    
    const msg = [`${username} ထံမှာတင်ရန်များ (Date: ${dateKey}):`];
    const buttons = [];
    
    for (const [num, amt] of Object.entries(overNumbers)) {
      buttons.push([{
        text: `${num.toString().padStart(2, '0')} ➤ ${amt} ⬜`,
        callback_data: `overbuy_select:${num}`
      }]);
    }
    
    buttons.push([
      { text: "Select All", callback_data: "overbuy_select_all" },
      { text: "Unselect All", callback_data: "overbuy_unselect_all" }
    ]);
    buttons.push([{ text: "OK", callback_data: "overbuy_confirm" }]);
    
    await editMessageText(chatId, callbackQueryId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in overbuy_unselect_all: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function overbuyConfirm(chatId, userId, callbackQueryId) {
  try {
    const context = { user_data: { overbuy_username: null, overbuy_date: null } };
    const username = context.user_data.overbuy_username;
    const dateKey = context.user_data.overbuy_date;
    
    if (!username || !dateKey) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: User or date not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    if (!overbuySelections[dateKey] || !overbuySelections[dateKey][username]) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: Selection data not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    const selectedNumbers = overbuySelections[dateKey][username];
    if (Object.keys(selectedNumbers).length === 0) {
      await editMessageText(chatId, callbackQueryId, "⚠️ ဘာဂဏန်းမှမရွေးထားပါ");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    if (!userData[username]) {
      userData[username] = {};
    }
    if (!userData[username][dateKey]) {
      userData[username][dateKey] = [];
    }
    
    let totalAmount = 0;
    const bets = [];
    
    for (const [numStr, amt] of Object.entries(selectedNumbers)) {
      const num = parseInt(numStr);
      userData[username][dateKey].push({ num, amt: -amt });
      bets.push(`${num.toString().padStart(2, '0')}-${amt}`);
      totalAmount += amt;
      
      // Update ledger
      ledger[dateKey][num] = (ledger[dateKey][num] || 0) - amt;
      if (ledger[dateKey][num] <= 0) {
        delete ledger[dateKey][num];
      }
    }
    
    // Initialize overbuy_list for date if needed
    if (!overbuyList[dateKey]) {
      overbuyList[dateKey] = {};
    }
    overbuyList[dateKey][username] = { ...selectedNumbers };
    
    const response = `${username} - ${dateKey}\n` + bets.join('\n') + `\nစုစုပေါင်း ${totalAmount} ကျပ်`;
    await editMessageText(chatId, callbackQueryId, response);
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in overbuy_confirm: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function pnumber(chatId, userId, args) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Determine which date to work on
    const dateKey = currentWorkingDate || getCurrentDateKey();
        
    if (!args) {
      if (pnumberPerDate[dateKey] !== undefined) {
        await sendMessage(chatId, `ℹ️ Usage: /pnumber [number]\nℹ️ ${dateKey} အတွက် Power Number: ${pnumberPerDate[dateKey].toString().padStart(2, '0')}`);
      } else {
        await sendMessage(chatId, `ℹ️ Usage: /pnumber [number]\nℹ️ ${dateKey} အတွက် Power Number မသတ်မှတ်ရသေးပါ`);
      }
      return;
    }
    
    try {
      const num = parseInt(args);
      if (num < 0 || num > 99) {
        await sendMessage(chatId, "⚠️ ဂဏန်းကို 0 နှင့် 99 ကြားထည့်ပါ");
        return;
      }
      
      pnumberPerDate[dateKey] = num;
      await sendMessage(chatId, `✅ ${dateKey} အတွက် Power Number ကို ${num.toString().padStart(2, '0')} အဖြစ်သတ်မှတ်ပြီး`);
      
      // Show report for this date
      const msg = [];
      let totalPower = 0;
      
      for (const [user, records] of Object.entries(userData)) {
        if (records[dateKey]) {
          let userTotal = 0;
          for (const { num: betNum, amt } of records[dateKey]) {
            if (betNum === num) {
              userTotal += amt;
            }
          }
          if (userTotal > 0) {
            msg.push(`${user}: ${num.toString().padStart(2, '0')} ➤ ${userTotal}`);
            totalPower += userTotal;
          }
        }
      }
      
      if (msg.length > 0) {
        msg.push(`\n🔴 ${dateKey} အတွက် Power Number စုစုပေါင်း: ${totalPower}`);
        await sendMessage(chatId, msg.join('\n'));
      } else {
        await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် ${num.toString().padStart(2, '0')} အတွက် လောင်းကြေးမရှိပါ`);
      }
    } catch {
      await sendMessage(chatId, "⚠️ ဂဏန်းမှန်မှန်ထည့်ပါ (ဥပမာ: /pnumber 15)");
    }
  } catch (e) {
    console.error(`Error in pnumber: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function comandza(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    if (Object.keys(userData).length === 0) {
      await sendMessage(chatId, "ℹ️ လက်ရှိ user မရှိပါ");
      return;
    }
    
    const users = Object.keys(userData);
    const buttons = users.map(u => [{
      text: u,
      callback_data: `comza:${u}`
    }]);
    
    await sendMessage(chatId, "👉 User ကိုရွေးပါ", {
      reply_markup: { inline_keyboard: buttons }
    });
  } catch (e) {
    console.error(`Error in comandza: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function comzaInput(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, username] = callbackData.split(':');
    const context = { user_data: { selected_user: username } };
    await editMessageText(chatId, callbackQueryId, `👉 ${context.user_data.selected_user} ကိုရွေးထားသည်။ 15/80 လို့ထည့်ပါ`);
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in comza_input: ${e}`);
    await answerCallbackQuery(callbackQueryId, `Error: ${e.message}`);
  }
}

async function comzaText(chatId, userId, text) {
  try {
    const context = { user_data: { selected_user: null } };
    const user = context.user_data.selected_user;
    if (!user) {
      await handleMessage(chatId, userId, null, null, text);
      return;
    }
    
    if (text && text.includes('/')) {
      try {
        const parts = text.split('/');
        if (parts.length !== 2) {
          throw new Error("Invalid format");
        }
        
        const com = parseInt(parts[0]);
        const za = parseInt(parts[1]);
        
        if (com < 0 || com > 100 || za < 0) {
          throw new Error("Invalid values");
        }
        
        comData[user] = com;
        zaData[user] = za;
        delete context.user_data.selected_user;
        await sendMessage(chatId, `✅ Com ${com}%, Za ${za} မှတ်ထားပြီး`);
      } catch {
        await sendMessage(chatId, "⚠️ မှန်မှန်ရေးပါ (ဥပမာ: 15/80)");
      }
    } else {
      await sendMessage(chatId, "⚠️ ဖော်မတ်မှားနေပါသည်။ 15/80 လို့ထည့်ပါ");
    }
  } catch (e) {
    console.error(`Error in comza_text: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function total(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Determine which date to work on
    const dateKey = currentWorkingDate || getCurrentDateKey();
        
    if (pnumberPerDate[dateKey] === undefined) {
      await sendMessage(chatId, `⚠️ ${dateKey} အတွက် ကျေးဇူးပြု၍ /pnumber [number] ဖြင့် Power Number သတ်မှတ်ပါ`);
      return;
    }
    
    if (Object.keys(userData).length === 0) {
      await sendMessage(chatId, "ℹ️ လက်ရှိစာရင်းမရှိပါ");
      return;
    }
    
    const pnum = pnumberPerDate[dateKey];
    const msg = [`📊 ${dateKey} အတွက် စုပေါင်းရလဒ်`];
    let totalNet = 0;
    
    for (const [user, records] of Object.entries(userData)) {
      if (records[dateKey]) {
        let userTotalAmt = 0;
        let userPamt = 0;
        
        for (const { num, amt } of records[dateKey]) {
          userTotalAmt += amt;
          if (num === pnum) {
            userPamt += amt;
          }
        }
        
        const com = comData[user] || 0;
        const za = zaData[user] || 80;
        
        const commissionAmt = Math.floor((userTotalAmt * com) / 100);
        const afterCom = userTotalAmt - commissionAmt;
        const winAmt = userPamt * za;
        
        const net = afterCom - winAmt;
        const status = net < 0 ? "ဒိုင်ကပေးရမည်" : "ဒိုင်ကရမည်";
        
        const userReport = [
          `👤 ${user}`,
          `💵 စုစုပေါင်း: ${userTotalAmt}`,
          `📊 Com(${com}%) ➤ ${commissionAmt}`,
          `💰 Com ပြီး: ${afterCom}`,
          `🔢 Power Number(${pnum.toString().padStart(2, '0')}) ➤ ${userPamt}`,
          `🎯 Za(${za}) ➤ ${winAmt}`,
          `📈 ရလဒ်: ${Math.abs(net)} (${status})`,
          "-----------------"
        ].join('\n');
        
        msg.push(userReport);
        totalNet += net;
      }
    }

    if (msg.length > 1) {
      msg.push(`\n📊 စုစုပေါင်းရလဒ်: ${Math.abs(totalNet)} (${totalNet < 0 ? 'ဒိုင်အရှုံး' : 'ဒိုင်အမြတ်'})`);
      await sendMessage(chatId, msg.join('\n'));
    } else {
      await sendMessage(chatId, `ℹ️ ${dateKey} အတွက် ဒေတာမရှိပါ`);
    }
  } catch (e) {
    console.error(`Error in total: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function tsent(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Determine which date to work on
    const dateKey = currentWorkingDate || getCurrentDateKey();
        
    if (Object.keys(userData).length === 0) {
      await sendMessage(chatId, "ℹ️ လက်ရှိ user မရှိပါ");
      return;
    }
    
    for (const [user, records] of Object.entries(userData)) {
      if (records[dateKey]) {
        const userReport = [`👤 ${user} - ${dateKey}:`];
        let totalAmt = 0;
        
        for (const { num, amt } of records[dateKey]) {
          userReport.push(`  - ${num.toString().padStart(2, '0')} ➤ ${amt}`);
          totalAmt += amt;
        }
        
        userReport.push(`💵 စုစုပေါင်း: ${totalAmt}`);
        await sendMessage(chatId, userReport.join('\n'));
      }
    }
    
    await sendMessage(chatId, `✅ ${dateKey} အတွက် စာရင်းများအားလုံး ပေးပို့ပြီးပါပြီ`);
  } catch (e) {
    console.error(`Error in tsent: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function alldata(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    if (Object.keys(userData).length === 0) {
      await sendMessage(chatId, "ℹ️ လက်ရှိစာရင်းမရှိပါ");
      return;
    }
    
    const msg = ["👥 မှတ်ပုံတင်ထားသော user များ:"];
    msg.push(...Object.keys(userData).map(u => `• ${u}`));
    
    await sendMessage(chatId, msg.join('\n'));
  } catch (e) {
    console.error(`Error in alldata: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function resetData(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    userData = {};
    ledger = {};
    zaData = {};
    comData = {};
    dateControl = {};
    overbuyList = {};
    overbuySelections = {};
    breakLimits = {};
    pnumberPerDate = {};
    currentWorkingDate = getCurrentDateKey();
    
    await sendMessage(chatId, "✅ ဒေတာများအားလုံးကို ပြန်လည်သုတ်သင်ပြီး လက်ရှိနေ့သို့ပြန်လည်သတ်မှတ်ပြီးပါပြီ");
  } catch (e) {
    console.error(`Error in reset_data: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function posthis(chatId, userId, args) {
  try {
    const isAdmin = userId === adminId;
    
    if (isAdmin && !args) {
      if (Object.keys(userData).length === 0) {
        await sendMessage(chatId, "ℹ️ လက်ရှိ user မရှိပါ");
        return;
      }
      
      const buttons = Object.keys(userData).map(u => [{
        text: u,
        callback_data: `posthis:${u}`
      }]);
      
      await sendMessage(chatId, "ဘယ် user ရဲ့စာရင်းကိုကြည့်မလဲ?", {
        reply_markup: { inline_keyboard: buttons }
      });
      return;
    }
    
    const username = isAdmin ? args : null;
    
    if (!username) {
      await sendMessage(chatId, "❌ User မရှိပါ");
      return;
    }
    
    if (!userData[username]) {
      await sendMessage(chatId, `ℹ️ ${username} အတွက် စာရင်းမရှိပါ`);
      return;
    }
    
    // For non-admin, show current date only
    const dateKey = !isAdmin ? getCurrentDateKey() : null;
    
    const msg = [`📊 ${username} ရဲ့လောင်းကြေးမှတ်တမ်း`];
    let totalAmount = 0;
    let pnumberTotal = 0;
    
    if (isAdmin) {
      // Admin can see all dates
      for (const [dateKey, records] of Object.entries(userData[username])) {
        const pnum = pnumberPerDate[dateKey];
        const pnumStr = pnum !== undefined ? ` [P: ${pnum.toString().padStart(2, '0')}]` : "";
        
        msg.push(`\n📅 ${dateKey}${pnumStr}:`);
        for (const { num, amt } of records) {
          if (pnum !== undefined && num === pnum) {
            msg.push(`🔴 ${num.toString().padStart(2, '0')} ➤ ${amt} 🔴`);
            pnumberTotal += amt;
          } else {
            msg.push(`${num.toString().padStart(2, '0')} ➤ ${amt}`);
          }
          totalAmount += amt;
        }
      }
    } else {
      // Non-admin only sees current date
      if (userData[username][dateKey]) {
        const pnum = pnumberPerDate[dateKey];
        const pnumStr = pnum !== undefined ? ` [P: ${pnum.toString().padStart(2, '0')}]` : "";
        
        msg.push(`\n📅 ${dateKey}${pnumStr}:`);
        for (const { num, amt } of userData[username][dateKey]) {
          if (pnum !== undefined && num === pnum) {
            msg.push(`🔴 ${num.toString().padStart(2, '0')} ➤ ${amt} 🔴`);
            pnumberTotal += amt;
          } else {
            msg.push(`${num.toString().padStart(2, '0')} ➤ ${amt}`);
          }
          totalAmount += amt;
        }
      }
    }
    
    if (msg.length > 1) {
      msg.push(`\n💵 စုစုပေါင်း: ${totalAmount}`);
      if (pnumberTotal > 0) {
        msg.push(`🔴 Power Number စုစုပေါင်း: ${pnumberTotal}`);
      }
      await sendMessage(chatId, msg.join('\n'));
    } else {
      await sendMessage(chatId, `ℹ️ ${username} အတွက် စာရင်းမရှိပါ`);
    }
  } catch (e) {
    console.error(`Error in posthis: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function posthisCallback(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, username] = callbackData.split(':');
    const msg = [`📊 ${username} ရဲ့လောင်းကြေးမှတ်တမ်း`];
    let totalAmount = 0;
    let pnumberTotal = 0;
    
    if (userData[username]) {
      for (const [dateKey, records] of Object.entries(userData[username])) {
        const pnum = pnumberPerDate[dateKey];
        const pnumStr = pnum !== undefined ? ` [P: ${pnum.toString().padStart(2, '0')}]` : "";
        
        msg.push(`\n📅 ${dateKey}${pnumStr}:`);
        for (const { num, amt } of records) {
          if (pnum !== undefined && num === pnum) {
            msg.push(`🔴 ${num.toString().padStart(2, '0')} ➤ ${amt} 🔴`);
            pnumberTotal += amt;
          } else {
            msg.push(`${num.toString().padStart(2, '0')} ➤ ${amt}`);
          }
          totalAmount += amt;
        }
      }
      
      if (msg.length > 1) {
        msg.push(`\n💵 စုစုပေါင်း: ${totalAmount}`);
        if (pnumberTotal > 0) {
          msg.push(`🔴 Power Number စုစုပေါင်း: ${pnumberTotal}`);
        }
        await editMessageText(chatId, callbackQueryId, msg.join('\n'));
      } else {
        await editMessageText(chatId, callbackQueryId, `ℹ️ ${username} အတွက် စာရင်းမရှိပါ`);
      }
    } else {
      await editMessageText(chatId, callbackQueryId, `ℹ️ ${username} အတွက် စာရင်းမရှိပါ`);
    }
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in posthis_callback: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function dateall(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Get all unique dates from user_data
    const allDates = getAvailableDates();
    
    if (allDates.length === 0) {
      await sendMessage(chatId, "ℹ️ မည်သည့်စာရင်းမှ မရှိသေးပါ");
      return;
    }
    
    // Initialize selection dictionary
    const dateallSelections = {};
    for (const date of allDates) {
      dateallSelections[date] = false;
    }
    const context = { user_data: { dateall_selections: dateallSelections } };
    
    // Build message with checkboxes
    const msg = ["📅 စာရင်းရှိသည့်နေ့ရက်များကို ရွေးချယ်ပါ:"];
    const buttons = [];
    
    for (const date of allDates) {
      const pnum = pnumberPerDate[date];
      const pnumStr = pnum !== undefined ? ` [P: ${pnum.toString().padStart(2, '0')}]` : "";
      
      const isSelected = dateallSelections[date];
      const buttonText = `${date}${pnumStr} ${isSelected ? '✅' : '⬜'}`;
      buttons.push([{
        text: buttonText,
        callback_data: `dateall_toggle:${date}`
      }]);
    }
    
    buttons.push([{
      text: "👁‍🗨 View",
      callback_data: "dateall_view"
    }]);
    
    await sendMessage(chatId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
  } catch (e) {
    console.error(`Error in dateall: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function dateallToggle(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, dateKey] = callbackData.split(':');
    const context = { user_data: { dateall_selections: {} } };
    const dateallSelections = context.user_data.dateall_selections;
    
    if (!dateallSelections[dateKey]) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: Date not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    // Toggle selection status
    dateallSelections[dateKey] = !dateallSelections[dateKey];
    context.user_data.dateall_selections = dateallSelections;
    
    // Rebuild the message with updated selections
    const msg = ["📅 စာရင်းရှိသည့်နေ့ရက်များကို ရွေးချယ်ပါ:"];
    const buttons = [];
    
    for (const date of Object.keys(dateallSelections)) {
      const pnum = pnumberPerDate[date];
      const pnumStr = pnum !== undefined ? ` [P: ${pnum.toString().padStart(2, '0')}]` : "";
      
      const isSelected = dateallSelections[date];
      const buttonText = `${date}${pnumStr} ${isSelected ? '✅' : '⬜'}`;
      buttons.push([{
        text: buttonText,
        callback_data: `dateall_toggle:${date}`
      }]);
    }
    
    buttons.push([{
      text: "👁‍🗨 View",
      callback_data: "dateall_view"
    }]);
    
    await editMessageText(chatId, callbackQueryId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in dateall_toggle: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function dateallView(chatId, userId, callbackQueryId) {
  try {
    const context = { user_data: { dateall_selections: {} } };
    const dateallSelections = context.user_data.dateall_selections;
    
    // 1. Get selected dates
    const selectedDates = Object.entries(dateallSelections)
      .filter(([_, selected]) => selected)
      .map(([date]) => date);
    
    if (selectedDates.length === 0) {
      await editMessageText(chatId, callbackQueryId, "⚠️ မည်သည့်နေ့ရက်ကိုမှ မရွေးချယ်ထားပါ");
      await answerCallbackQuery(callbackQueryId);
      return;
    }

    // 2. Initialize data storage
    const userReports = {};  // {username: {total_bet: 0, power_bet: 0, com: X, za: Y}}
    const grandTotals = {
      total_bet: 0,
      power_bet: 0,
      commission: 0,
      win_amount: 0,
      net_result: 0
    };

    // 3. Process bets WITHOUT overbuy adjustment
    for (const [username, userDates] of Object.entries(userData)) {
      if (!userReports[username]) {
        userReports[username] = {
          total_bet: 0,
          power_bet: 0,
          com: comData[username] || 0,
          za: zaData[username] || 80
        };
      }
      
      for (const dateKey of selectedDates) {
        if (userDates[dateKey]) {
          // Track total bets
          const dateTotal = userDates[dateKey].reduce((sum, { amt }) => sum + amt, 0);
          userReports[username].total_bet += dateTotal;
          
          // Track power number bets
          const pnum = pnumberPerDate[dateKey];
          if (pnum !== undefined) {
            const powerAmt = userDates[dateKey]
              .filter(({ num }) => num === pnum)
              .reduce((sum, { amt }) => sum + amt, 0);
            userReports[username].power_bet += powerAmt;
          }
        }
      }
    }

    // 4. Calculate financials
    const messages = ["📊 ရွေးချယ်ထားသော နေ့ရက်များ စုစုပေါင်းရလဒ် (Overbuy မပါ)"];
    messages.push(`📅 ရက်စွဲများ: ${selectedDates.join(', ')}\n`);
    
    for (const [username, report] of Object.entries(userReports)) {
      // Calculate values
      const commission = Math.floor((report.total_bet * report.com) / 100);
      const afterCom = report.total_bet - commission;
      const winAmount = report.power_bet * report.za;
      const netResult = afterCom - winAmount;
      
      // Build user message
      const userMsg = [
        `👤 ${username}`,
        `💵 စုစုပေါင်းလောင်းကြေး: ${report.total_bet}`,
        `📊 Com (${report.com}%): ${commission}`,
        `💰 Com ပြီး: ${afterCom}`
      ];
      
      if (report.power_bet > 0) {
        userMsg.push(
          `🔴 Power Number: ${report.power_bet}`,
          `🎯 Za (${report.za}): ${winAmount}`
        );
      }
      
      userMsg.push(
        `📈 ရလဒ်: ${Math.abs(netResult)} (${netResult < 0 ? 'ဒိုင်ကပေးရန်' : 'ဒိုင်ကရမည်'})`
      );
      
      messages.push(userMsg.join('\n'));
      messages.push("⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯");
      
      // Update grand totals
      grandTotals.total_bet += report.total_bet;
      grandTotals.power_bet += report.power_bet;
      grandTotals.commission += commission;
      grandTotals.win_amount += winAmount;
      grandTotals.net_result += netResult;
    }

    // 5. Add grand totals
    messages.push("\n📌 စုစုပေါင်းရလဒ်:");
    messages.push(`💵 စုစုပေါင်းလောင်းကြေး: ${grandTotals.total_bet}`);
    messages.push(`📊 Com စုစုပေါင်း: ${grandTotals.commission}`);
    
    if (grandTotals.power_bet > 0) {
      messages.push(`🔴 Power Number စုစုပေါင်း: ${grandTotals.power_bet}`);
      messages.push(`🎯 Win Amount စုစုပေါင်း: ${grandTotals.win_amount}`);
    }
    
    messages.push(
      `📊 စုစုပေါင်းရလဒ်: ${Math.abs(grandTotals.net_result)} ` +
      `(${grandTotals.net_result < 0 ? 'ဒိုင်အရှုံး' : 'ဒိုင်အမြတ်'})`
    );

    // 6. Send message (split if too long)
    const fullMessage = messages.join('\n');
    if (fullMessage.length > 4000) {
      const half = Math.floor(messages.length / 2);
      await editMessageText(chatId, callbackQueryId, messages.slice(0, half).join('\n'));
      await sendMessage(chatId, messages.slice(half).join('\n'));
    } else {
      await editMessageText(chatId, callbackQueryId, fullMessage);
    }
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in dateall_view: ${e}`);
    await editMessageText(chatId, callbackQueryId, "❌ တွက်ချက်မှုအမှားဖြစ်နေပါသည်");
    await answerCallbackQuery(callbackQueryId);
  }
}

async function changeWorkingDate(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    const keyboard = [
      [{ text: "🗓 လက်ရှိလအတွက် ပြက္ခဒိန်", callback_data: "cdate_calendar" }],
      [{ text: "⏰ AM ရွေးရန်", callback_data: "cdate_am" }],
      [{ text: "🌙 PM ရွေးရန်", callback_data: "cdate_pm" }],
      [{ text: "📆 ယနေ့ဖွင့်ရန်", callback_data: "cdate_open" }]
    ];
    
    await sendMessage(chatId,
      "👉 လက်ရှိ အလုပ်လုပ်ရမည့်နေ့ရက်ကို ရွေးချယ်ပါ\n" +
      "• ပြက္ခဒိန်ဖြင့်ရွေးရန်: 🗓 ခလုတ်ကိုနှိပ်ပါ\n" +
      "• AM သို့ပြောင်းရန်: ⏰ ခလုတ်ကိုနှိပ်ပါ\n" +
      "• PM သို့ပြောင်းရန်: 🌙 ခလုတ်ကိုနှိပ်ပါ\n" +
      "• ယနေ့သို့ပြန်ရန်: 📆 ခလုတ်ကိုနှိပ်ပါ",
      { reply_markup: { inline_keyboard: keyboard } }
    );
  } catch (e) {
    console.error(`Error in change_working_date: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function showCalendar(chatId, userId, callbackQueryId) {
  try {
    const now = new Date(new Date().toLocaleString('en-US', { timeZone: MYANMAR_TIMEZONE }));
    const year = now.getFullYear();
    const month = now.getMonth() + 1;
    
    // Create calendar header
    const monthNames = ["January", "February", "March", "April", "May", "June",
      "July", "August", "September", "October", "November", "December"];
    const calHeader = monthNames[month - 1] + " " + year;
    const days = ["တနင်္လာ", "အင်္ဂါ", "ဗုဒ္ဓဟူး", "ကြာသပတေး", "သောကြာ", "စနေ", "တနင်္ဂနွေ"];
    
    // Generate calendar days
    const firstDay = new Date(year, month - 1, 1).getDay();
    const daysInMonth = new Date(year, month, 0).getDate();
    
    let cal = [];
    let week = Array(7).fill(0);
    
    let day = 1;
    for (let i = 0; i < 6; i++) {
      if (day > daysInMonth) break;
      
      for (let j = 0; j < 7; j++) {
        if ((i === 0 && j < firstDay) || day > daysInMonth) {
          week[j] = 0;
        } else {
          week[j] = day++;
        }
      }
      cal.push([...week]);
    }
    
    const keyboard = [];
    keyboard.push([{ text: calHeader, callback_data: "ignore" }]);
    keyboard.push(days.map(day => ({ text: day, callback_data: "ignore" })));
    
    for (const week of cal) {
      const weekButtons = [];
      for (const day of week) {
        if (day === 0) {
          weekButtons.push({ text: " ", callback_data: "ignore" });
        } else {
          const dateStr = `${day.toString().padStart(2, '0')}/${month.toString().padStart(2, '0')}/${year}`;
          weekButtons.push({ text: day.toString(), callback_data: `cdate_day:${dateStr}` });
        }
      }
      keyboard.push(weekButtons);
    }
    
    // Add navigation and back buttons
    keyboard.push([
      { text: "⬅️ ယခင်", callback_data: "cdate_prev_month" },
      { text: "➡️ နောက်", callback_data: "cdate_next_month" }
    ]);
    keyboard.push([{ text: "🔙 နောက်သို့", callback_data: "cdate_back" }]);
    
    await editMessageText(chatId, callbackQueryId, "🗓 နေ့ရက်ရွေးရန် ပြက္ခဒိန်", {
      reply_markup: { inline_keyboard: keyboard }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in show_calendar: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function handleDaySelection(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, dateStr] = callbackData.split(':');
    const context = { user_data: { selected_date: dateStr } };
    
    // Ask for AM/PM selection
    const keyboard = [
      [{ text: "⏰ AM", callback_data: "cdate_set_am" }],
      [{ text: "🌙 PM", callback_data: "cdate_set_pm" }],
      [{ text: "🔙 နောက်သို့", callback_data: "cdate_back" }]
    ];
    
    await editMessageText(chatId, callbackQueryId, `👉 ${dateStr} အတွက် အချိန်ပိုင်းရွေးပါ`, {
      reply_markup: { inline_keyboard: keyboard }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in handle_day_selection: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function setAmPm(chatId, userId, callbackQueryId, callbackData) {
  try {
    const timeSegment = callbackData.includes('am') ? 'AM' : 'PM';
    const context = { user_data: { selected_date: '' } };
    const dateStr = context.user_data.selected_date;
    
    if (!dateStr) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: Date not selected");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    currentWorkingDate = `${dateStr} ${timeSegment}`;
    await editMessageText(chatId, callbackQueryId, `✅ လက်ရှိ အလုပ်လုပ်ရမည့်နေ့ရက်ကို ${currentWorkingDate} အဖြစ်ပြောင်းလိုက်ပါပြီ`);
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in set_am_pm: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function setAm(chatId, userId, callbackQueryId) {
  try {
    if (currentWorkingDate) {
      const datePart = currentWorkingDate.split(' ')[0];
      currentWorkingDate = `${datePart} AM`;
      await editMessageText(chatId, callbackQueryId, `✅ လက်ရှိ အလုပ်လုပ်ရမည့်နေ့ရက်ကို ${currentWorkingDate} အဖြစ်ပြောင်းလိုက်ပါပြီ`);
    } else {
      await editMessageText(chatId, callbackQueryId, "❌ လက်ရှိနေ့ရက် သတ်မှတ်ထားခြင်းမရှိပါ");
    }
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in set_am: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function setPm(chatId, userId, callbackQueryId) {
  try {
    if (currentWorkingDate) {
      const datePart = currentWorkingDate.split(' ')[0];
      currentWorkingDate = `${datePart} PM`;
      await editMessageText(chatId, callbackQueryId, `✅ လက်ရှိ အလုပ်လုပ်ရမည့်နေ့ရက်ကို ${currentWorkingDate} အဖြစ်ပြောင်းလိုက်ပါပြီ`);
    } else {
      await editMessageText(chatId, callbackQueryId, "❌ လက်ရှိနေ့ရက် သတ်မှတ်ထားခြင်းမရှိပါ");
    }
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in set_pm: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function openCurrentDate(chatId, userId, callbackQueryId) {
  try {
    currentWorkingDate = getCurrentDateKey();
    await editMessageText(chatId, callbackQueryId, `✅ လက်ရှိ အလုပ်လုပ်ရမည့်နေ့ရက်ကို ${currentWorkingDate} အဖြစ်ပြောင်းလိုက်ပါပြီ`);
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in open_current_date: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function navigateMonth(chatId, userId, callbackQueryId) {
  await answerCallbackQuery(callbackQueryId);
  await editMessageText(chatId, callbackQueryId, "ℹ️ လများလှန်ကြည့်ခြင်းအား နောက်ထပ်ဗားရှင်းတွင် ထည့်သွင်းပါမည်");
}

async function backToMain(chatId, userId, callbackQueryId) {
  await answerCallbackQuery(callbackQueryId);
  await changeWorkingDate(chatId, userId);
}

async function deleteDate(chatId, userId) {
  try {
    if (userId !== adminId) {
      await sendMessage(chatId, "❌ Admin only command");
      return;
    }
    
    // Get all available dates
    const availableDates = getAvailableDates();
    
    if (availableDates.length === 0) {
      await sendMessage(chatId, "ℹ️ မည်သည့်စာရင်းမှ မရှိသေးပါ");
      return;
    }
    
    // Initialize selection dictionary
    const datedeleteSelections = {};
    for (const date of availableDates) {
      datedeleteSelections[date] = false;
    }
    const context = { user_data: { datedelete_selections: datedeleteSelections } };
    
    // Build message with checkboxes
    const msg = ["🗑 ဖျက်လိုသောနေ့ရက်များကို ရွေးချယ်ပါ:"];
    const buttons = [];
    
    for (const date of availableDates) {
      const pnum = pnumberPerDate[date];
      const pnumStr = pnum !== undefined ? ` [P: ${pnum.toString().padStart(2, '0')}]` : "";
      
      const isSelected = datedeleteSelections[date];
      const buttonText = `${date}${pnumStr} ${isSelected ? '✅' : '⬜'}`;
      buttons.push([{
        text: buttonText,
        callback_data: `datedelete_toggle:${date}`
      }]);
    }
    
    buttons.push([{
      text: "✅ Delete Selected",
      callback_data: "datedelete_confirm"
    }]);
    
    await sendMessage(chatId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
  } catch (e) {
    console.error(`Error in delete_date: ${e}`);
    await sendMessage(chatId, `❌ Error: ${e.message}`);
  }
}

async function datedeleteToggle(chatId, userId, callbackQueryId, callbackData) {
  try {
    const [_, dateKey] = callbackData.split(':');
    const context = { user_data: { datedelete_selections: {} } };
    const datedeleteSelections = context.user_data.datedelete_selections;
    
    if (!datedeleteSelections[dateKey]) {
      await editMessageText(chatId, callbackQueryId, "❌ Error: Date not found");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    // Toggle selection status
    datedeleteSelections[dateKey] = !datedeleteSelections[dateKey];
    context.user_data.datedelete_selections = datedeleteSelections;
    
    // Rebuild the message with updated selections
    const msg = ["🗑 ဖျက်လိုသောနေ့ရက်များကို ရွေးချယ်ပါ:"];
    const buttons = [];
    
    for (const date of Object.keys(datedeleteSelections)) {
      const pnum = pnumberPerDate[date];
      const pnumStr = pnum !== undefined ? ` [P: ${pnum.toString().padStart(2, '0')}]` : "";
      
      const isSelected = datedeleteSelections[date];
      const buttonText = `${date}${pnumStr} ${isSelected ? '✅' : '⬜'}`;
      buttons.push([{
        text: buttonText,
        callback_data: `datedelete_toggle:${date}`
      }]);
    }
    
    buttons.push([{
      text: "✅ Delete Selected",
      callback_data: "datedelete_confirm"
    }]);
    
    await editMessageText(chatId, callbackQueryId, msg.join('\n'), {
      reply_markup: { inline_keyboard: buttons }
    });
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in datedelete_toggle: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

async function datedeleteConfirm(chatId, userId, callbackQueryId) {
  try {
    const context = { user_data: { datedelete_selections: {} } };
    const datedeleteSelections = context.user_data.datedelete_selections;
    
    // Get selected dates
    const selectedDates = Object.entries(datedeleteSelections)
      .filter(([_, selected]) => selected)
      .map(([date]) => date);
    
    if (selectedDates.length === 0) {
      await editMessageText(chatId, callbackQueryId, "⚠️ မည်သည့်နေ့ရက်ကိုမှ မရွေးချယ်ထားပါ");
      await answerCallbackQuery(callbackQueryId);
      return;
    }
    
    // Delete data for selected dates
    for (const dateKey of selectedDates) {
      // Remove from user_data
      for (const user of Object.keys(userData)) {
        if (userData[user][dateKey]) {
          delete userData[user][dateKey];
        }
        // Remove user if no dates left
        if (Object.keys(userData[user]).length === 0) {
          delete userData[user];
        }
      }
      
      // Remove from ledger
      if (ledger[dateKey]) {
        delete ledger[dateKey];
      }
      
      // Remove from break_limits
      if (breakLimits[dateKey]) {
        delete breakLimits[dateKey];
      }
      
      // Remove from pnumber_per_date
      if (pnumberPerDate[dateKey]) {
        delete pnumberPerDate[dateKey];
      }
      
      // Remove from date_control
      if (dateControl[dateKey]) {
        delete dateControl[dateKey];
      }
      
      // Remove from overbuy_list
      if (overbuyList[dateKey]) {
        delete overbuyList[dateKey];
      }
      
      // Remove from overbuy_selections
      if (overbuySelections[dateKey]) {
        delete overbuySelections[dateKey];
      }
    }
    
    // Clear current working date if it was deleted
    if (selectedDates.includes(currentWorkingDate)) {
      currentWorkingDate = null;
    }
    
    await editMessageText(chatId, callbackQueryId, 
      `✅ အောက်ပါနေ့ရက်များ ဖျက်ပြီးပါပြီ:\n${selectedDates.join(', ')}`);
    await answerCallbackQuery(callbackQueryId);
  } catch (e) {
    console.error(`Error in datedelete_confirm: ${e}`);
    await answerCallbackQuery(callbackQueryId, "Error occurred");
  }
}

// Main request handler
async function handleRequest(request) {
  if (request.method === 'POST') {
    try {
      const update = await request.json();
      
      // Handle callback queries
      if (update.callback_query) {
        const callbackQuery = update.callback_query;
        const chatId = callbackQuery.message.chat.id;
        const userId = callbackQuery.from.id;
        const callbackQueryId = callbackQuery.id;
        const callbackData = callbackQuery.data;
        
        if (callbackData.startsWith('delete:')) {
          await deleteBet(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData.startsWith('confirm_delete:')) {
          await confirmDelete(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData.startsWith('cancel_delete:')) {
          await cancelDelete(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData.startsWith('overbuy_select:')) {
          await overbuySelect(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData === 'overbuy_select_all') {
          await overbuySelectAll(chatId, userId, callbackQueryId);
        } else if (callbackData === 'overbuy_unselect_all') {
          await overbuyUnselectAll(chatId, userId, callbackQueryId);
        } else if (callbackData === 'overbuy_confirm') {
          await overbuyConfirm(chatId, userId, callbackQueryId);
        } else if (callbackData.startsWith('posthis:')) {
          await posthisCallback(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData.startsWith('dateall_toggle:')) {
          await dateallToggle(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData === 'dateall_view') {
          await dateallView(chatId, userId, callbackQueryId);
        } else if (callbackData === 'cdate_calendar') {
          await showCalendar(chatId, userId, callbackQueryId);
        } else if (callbackData.startsWith('cdate_day:')) {
          await handleDaySelection(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData === 'cdate_set_am' || callbackData === 'cdate_set_pm') {
          await setAmPm(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData === 'cdate_am') {
          await setAm(chatId, userId, callbackQueryId);
        } else if (callbackData === 'cdate_pm') {
          await setPm(chatId, userId, callbackQueryId);
        } else if (callbackData === 'cdate_open') {
          await openCurrentDate(chatId, userId, callbackQueryId);
        } else if (callbackData === 'cdate_prev_month' || callbackData === 'cdate_next_month') {
          await navigateMonth(chatId, userId, callbackQueryId);
        } else if (callbackData === 'cdate_back') {
          await backToMain(chatId, userId, callbackQueryId);
        } else if (callbackData.startsWith('datedelete_toggle:')) {
          await datedeleteToggle(chatId, userId, callbackQueryId, callbackData);
        } else if (callbackData === 'datedelete_confirm') {
          await datedeleteConfirm(chatId, userId, callbackQueryId);
        } else if (callbackData.startsWith('comza:')) {
          await comzaInput(chatId, userId, callbackQueryId, callbackData);
        } else {
          await answerCallbackQuery(callbackQueryId);
        }
      }
      // Handle messages
      else if (update.message) {
        const message = update.message;
        const chatId = message.chat.id;
        const userId = message.from.id;
        const username = message.from.username;
        const messageId = message.message_id;
        const text = message.text || '';
        
        // Handle commands
        if (text.startsWith('/')) {
          const command = text.split(' ')[0].substring(1).toLowerCase();
          const args = text.split(' ').slice(1).join(' ');
          
          switch (command) {
            case 'start':
              await handleStart(chatId, userId, username);
              break;
            case 'menu':
              await showMenu(chatId, userId);
              break;
            case 'dateopen':
              await dateOpen(chatId, userId);
              break;
            case 'dateclose':
              await dateClose(chatId, userId);
              break;
            case 'ledger':
              await ledgerSummary(chatId, userId);
              break;
            case 'break':
              await breakCommand(chatId, userId, args);
              break;
            case 'overbuy':
              await overbuy(chatId, userId, args);
              break;
            case 'pnumber':
              await pnumber(chatId, userId, args);
              break;
            case 'comandza':
              await comandza(chatId, userId);
              break;
            case 'total':
              await total(chatId, userId);
              break;
            case 'tsent':
              await tsent(chatId, userId);
              break;
            case 'alldata':
              await alldata(chatId, userId);
              break;
            case 'reset':
              await resetData(chatId, userId);
              break;
            case 'posthis':
              await posthis(chatId, userId, args);
              break;
            case 'dateall':
              await dateall(chatId, userId);
              break;
            case 'cdate':
              await changeWorkingDate(chatId, userId);
              break;
            case 'ddate':
              await deleteDate(chatId, userId);
              break;
            default:
              await handleMenuSelection(chatId, userId, text);
          }
        } 
        // Handle menu selections
        else if (/^[\u1000-\u109F\s]+$/.test(text)) {
          await handleMenuSelection(chatId, userId, text);
        }
        // Handle regular messages
        else {
          await handleMessage(chatId, userId, username, messageId, text);
        }
      }
      
      return new Response('OK', { status: 200 });
    } catch (e) {
      console.error(`Error handling update: ${e}`);
      return new Response('Error handling update', { status: 500 });
    }
  }
  
  return new Response('Method not allowed', { status: 405 });
}

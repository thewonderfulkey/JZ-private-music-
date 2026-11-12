package com.jz.musichelper.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jz.musichelper.ui.theme.LocalPalette

// ===== 搜索栏 v2.1.59：真输入框，不是画框 =====
// v2.1.35–v2.1.58 那版是"一幅渲染出来的水墨横幅"（328dp 宽 × 96dp 高，山水 + 红日当按钮）：
// 首页诊断里它被一眼看成装饰画框——用户不知道能打字，也不知道点下去会发生什么。
// 现在：白底 44dp 输入框 + 左侧放大镜 + 明确占位文案 + 有字才出现的清除钮，边界清楚、层级清楚。
// 交互沿用旧口径：聚焦即展开搜索历史（关键词为空时），回车/搜索键触发搜索。
@Composable
fun InkSearchBar(
    keyword: String,
    onKeywordChange: (String) -> Unit,
    onSearch: () -> Unit,
    isSearching: Boolean,
    onToggleHistory: () -> Unit,
    onClear: () -> Unit
) {
    val p = LocalPalette.current
    val kb = LocalSoftwareKeyboardController.current
    var focused by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(44.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xFFFFFFFF))
            .border(1.dp, Color(0x1422201B), RoundedCornerShape(10.dp))
            .padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.Search,
                contentDescription = null,
                tint = p.text3,
                modifier = Modifier.size(16.dp)
            )
            Spacer(Modifier.width(8.dp))
            Box(modifier = Modifier.weight(1f)) {
                if (keyword.isEmpty()) {
                    Text("搜索歌曲、歌手、专辑", fontSize = 14.sp, color = p.text3, maxLines = 1)
                }
                BasicTextField(
                    value = keyword,
                    onValueChange = onKeywordChange,
                    singleLine = true,
                    textStyle = TextStyle(fontSize = 14.sp, color = p.text),
                    cursorBrush = SolidColor(p.accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = {
                        onSearch()
                        kb?.hide()
                    }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .onFocusChanged { st ->
                            if (st.isFocused && !focused) {
                                focused = true
                                if (keyword.isEmpty()) onToggleHistory()
                            } else if (!st.isFocused) {
                                focused = false
                            }
                        }
                )
            }
            if (isSearching) {
                Spacer(Modifier.width(6.dp))
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = p.accent2, strokeWidth = 2.dp)
            } else if (keyword.isNotEmpty()) {
                Spacer(Modifier.width(6.dp))
                Icon(
                    Icons.Filled.Close,
                    contentDescription = "清空",
                    tint = p.text3,
                    modifier = Modifier
                        .size(18.dp)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null
                        ) { onClear() }
                )
            }
        }
    }
}

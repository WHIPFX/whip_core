// GTA V's settings page (pause_menu_pages_settings.gfx), decompiled, with whip's questions added: getColumn and the
// whip* functions after stateChanged, and setupPage's last line (whipWatchMemory). Everything else is Rockstar's, as
// the game has it. How to build the .gfx from this: README.md beside it.
class com.rockstargames.gtav.pauseMenuPages.PAUSE_MENU_PAGES_SETTINGS extends com.rockstargames.gtav.pauseMenuPages.PauseMenuBasePage
{
   var addColumn;
   var column1;
   var column2;
   var columnList;
   var setupColMouseNav;
   var setupColScroll;
   var setupColumns;
   var showColumns;
   var timelineMC;
   var whipColumn;
   var whipMemory;
   function PAUSE_MENU_PAGES_SETTINGS()
   {
      super();
   }
   function setupPage()
   {
      super.setupPage();
      this.column1 = this.addColumn("freemodeList",1,0);
      this.column2 = this.addColumn("settingsList",2,290);
      this.setupColumns(this.column1,this.column2);
      this.setupColScroll([this.column1,this.column2],[true,true]);
      this.setupColMouseNav([this.column1,this.column2],[true,true]);
      this.whipWatchMemory();
   }
   function stateChanged(id)
   {
      super.stateChanged(id);
      this.columnList = [this.column1,this.column2];
      switch(id)
      {
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_CONTROLS:
            this.column2.SET_STATE(com.rockstargames.gtav.pauseMenu.pauseComponents.PAUSE_MENU_SETTINGS.CUSTOM_ITEM_CONTROLS);
            break;
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_FACEBOOK:
            this.column2.SET_STATE(com.rockstargames.gtav.pauseMenu.pauseComponents.PAUSE_MENU_SETTINGS.CUSTOM_ITEM_SOCIAL);
            break;
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_AUDIO:
            this.column2.SET_STATE(com.rockstargames.gtav.pauseMenu.pauseComponents.PAUSE_MENU_SETTINGS.CUSTOM_ITEM_AUDIO);
            break;
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_MISC_CONTROLS:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_DISPLAY:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_CAMERA:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_VIDEO:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_GRAPHICS:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_VOICE_CHAT:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_FEED:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_REPLAY:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_SAVEGAME:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_SIXAXIS:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_FIRST_PERSON:
         case com.rockstargames.gtav.constants.PauseMenuLUT.SETTINGS_AGE_ASSURANCE:
            this.column2.SET_STATE(0);
      }
      this.showColumns();
   }
   // whip's questions arrive as the column GET_COLUMN_SELECTION asks for: "whip|<what>|...". They are answered here,
   // and the answer is what that column's selection reads; every other column is GTA's, as before.
   function getColumn(i)
   {
      if(typeof i == "string" && i.substr(0,5) == "whip|")
      {
         if(this.whipColumn == undefined)
         {
            this.whipColumn = new Object();
            this.whipColumn.model = new Object();
            this.whipColumn.model.getCurrentSelection = function()
            {
               return this.answer;
            };
         }
         this.whipColumn.model.answer = this.whipAnswer(i.split("|"));
         return this.whipColumn;
      }
      return super.getColumn(i);
   }
   // GTA's video memory bar (the Graphics tabs): what GTA hands the settings column, kept for whip|vidmem as it passes
   // on to the column's own drawing. [label, percent, second percent or -1].
   function whipWatchMemory()
   {
      var c = this.column2;
      if(c == undefined || c.whipPage != undefined)
      {
         return undefined;
      }
      c.whipPage = this;
      c.whipBar = c.SET_VIDEO_MEMORY_BAR;
      c.whipBar2 = c.SET_VIDEO_MEMORY_BAR_2;
      c.SET_VIDEO_MEMORY_BAR = function(initialise, textlabel, percent, colour)
      {
         this.whipPage.whipMemory = [textlabel,percent,-1];
         return this.whipBar.apply(this,arguments);
      };
      c.SET_VIDEO_MEMORY_BAR_2 = function(initialise, textlabel, percent, colour, percent2, colour2)
      {
         this.whipPage.whipMemory = [textlabel,percent,percent2];
         return this.whipBar2.apply(this,arguments);
      };
   }
   // The pause menu's content movie, which mouse presses go through.
   function whipContent()
   {
      return this.timelineMC._parent._parent._parent.TIMELINE;
   }
   function whipRows(column)
   {
      var view = column.model.getCurrentView();
      if(view == undefined || view.dataList == undefined)
      {
         return [];
      }
      return view.dataList;
   }
   // Every answer starts W1 (answered) or W0 (no such row). Column 1 is the tabs, 2 the settings. A row's data is what
   // GTA set it with: [0] index, [1] menuID, [2] uniqueID, [3] type, [4] value, [5] state, [6] label, [7...] options.
   //   whip|head                       tabs, rows, the tab chosen, the menu's state, the first and last row's ids
   //   whip|row|<col>|<i>              menuID, uniqueID, type, value, state, how many options
   //   whip|text|<col>|<i>|<n>|<from>|<len>   field n's text, len characters from `from`
   //   whip|click|<col>|<i>            the row clicked, as the mouse does
   //   whip|vidmem                     the video memory bar's percent and second percent (-1: none); W0 before GTA set it
   //   whip|vidtext|<from>|<len>       its label, len characters from `from`
   //   whip|changed                    how many settings rows GTA marks as changed and not applied (on a row drawn, or
   //                                   in a row's data)
   // ("If ... else": FFDec's compiler misreads (a ? b : c)[i].)
   function whipAnswer(q)
   {
      var what = q[1];
      var cats = this.whipRows(this.column1);
      var rows = this.whipRows(this.column2);
      var d;
      var view;
      var n;
      var i;
      if(what == "changed")
      {
         n = 0;
         i = 0;
         while(i < rows.length)
         {
            if(rows[i][5] == 2)
            {
               n++;
            }
            i++;
         }
         view = this.column2.model.getCurrentView();
         i = 0;
         while(view != undefined && i < view.itemList.length)
         {
            if(view.itemList[i].isChanged == true)
            {
               n++;
            }
            i++;
         }
         return "W1|" + n;
      }
      if(what == "head")
      {
         view = this.column1.model.getCurrentView();
         d = rows.length > 0 ? rows[0][2] + "." + rows[rows.length - 1][2] : "";
         return ["W1",cats.length,rows.length,view == undefined ? -1 : view.index,this.whipContent().menuState,d].join("|");
      }
      if(what == "vidmem" || what == "vidtext")
      {
         d = this.whipMemory;
         if(d == undefined)
         {
            return "W0";
         }
         if(what == "vidmem")
         {
            return ["W1",d[1],d[2]].join("|");
         }
         return "W1|" + String(d[0]).substr(Number(q[2]),Number(q[3]));
      }
      if(q[2] == "1")
      {
         d = cats[Number(q[3])];
      }
      else
      {
         d = rows[Number(q[3])];
      }
      if(d == undefined)
      {
         return "W0";
      }
      if(what == "row")
      {
         return ["W1",d[1],d[2],d[3],d[4],d[5],d.length - 7].join("|");
      }
      if(what == "text")
      {
         return "W1|" + String(d[Number(q[4])]).substr(Number(q[5]),Number(q[6]));
      }
      if(what == "click")
      {
         this.whipContent().M_PRESS_EVENT(Number(q[3]),q[2] == "1" ? 0 : 1,false);
         return "W1";
      }
      return "W0";
   }
}

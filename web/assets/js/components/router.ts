// @ts-nocheck
import { Component } from "sevejs";
import barba from "@barba/core";
import { gsap } from "gsap";

import { playView, playTransition } from "../routes/play.ts";
import { homeTransition, homeView } from "../routes/home.ts";

const Router = class extends Component {
  constructor(opts: any) {
    super(opts); // "opts" arg from constructor to super is a mandatory to share components across the app
  }

  init() {
    // automatically called at start
    console.log("Router component init");

    this.loadedViews = [playView, homeView];
    this.loadedTransition = [playTransition, homeTransition];
    this.views = [];
    this.transitions = [];

    this._updateModules();
    this._createModules("views", this.loadedViews);
    this._createModules("transitions", this.loadedTransition);

    barba.init({
      views: this.views,
      transitions: this.transitions,
    });
  }

  /**
   * BARBA MODULE CREATION
   * @param {string} type ['views'|'transitions']
   * @param {array} modules
   */
  _createModules(type, modules = []) {
    modules.forEach((module) => this[type].push(module));
  }

  /**
   * INIT MODULES UPDATE (MODUJS across BARBAJS)
   */
  _updateModules() {
    this.loadedViews.forEach((loadedView) => {
      /** Check if barba after/before function exist then yes save it */
      const viewAfterFunc = loadedView.afterEnter ? loadedView.afterEnter : null;
      const viewBeforeFunc = loadedView.beforeLeave ? loadedView.beforeLeave : null;

      loadedView.beforeLeave = (data) => {
        viewBeforeFunc && viewBeforeFunc();

        // Other general actions...
      };

      /** init barba after function if exist then create Modularjs update func */
      loadedView.afterEnter = (data) => {
        viewAfterFunc && viewAfterFunc();

        // Global Emit
        this.trigger("pageLoad");

        // Other general actions...

        /** if not first load -> modularjs already init in general index.js */
        if (data.current.container) {
          this.call("destroy", data.current.container, "app");
          this.call("update", data.next.container, "app");
        }
      };
    });
  }

  destroy() {
    barba.destroy();
  }
};

export { Router };

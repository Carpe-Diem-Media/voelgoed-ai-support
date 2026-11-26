const csrf = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new LiveView.LiveSocket("/staff/live", Phoenix.Socket, {
  params: { _csrf_token: csrf },
  hooks: {
    StaffForm: {
      disconnected() {
        this.el.querySelector("fieldset").disabled = true;
      },
      reconnected() {
        this.el.querySelector("fieldset").disabled = false;
      },
    },
  },
});
liveSocket.connect();

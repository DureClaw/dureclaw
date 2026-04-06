defmodule HarnessServer.Endpoint do
  use Phoenix.Endpoint, otp_app: :harness_server

  socket("/socket", HarnessServer.UserSocket,
    websocket: [
      timeout: 60_000,
      check_origin: false
    ],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(HarnessServer.Router)
end
